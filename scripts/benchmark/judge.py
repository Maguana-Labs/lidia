#!/usr/bin/env python3
"""LLM-as-judge for the LidIA summary benchmark (docs/research/2026-11-summary-benchmark.md).

Scores summaries produced by `SummaryBenchmarkTests` against Granola's summary of
the same meeting, with Claude as the judge and a cheap word-overlap metric as a
cross-check.

Privacy: transcripts and summaries are read from a COPY of the library and from
the benchmark's JSONL output, sent only to the Anthropic API, and results are
written to OUT_DIR (keep it outside the repo). Nothing private is printed.

Usage:
  judge.py keypoints DB OUT_DIR PK [PK ...]          # once: key points from Granola's notes
  judge.py score DB OUT_DIR LABEL [JSONL ...]         # score one run (all models, blinded)
  judge.py routing ITEMS_JSON ANSWERS_JSON OUT_DIR    # label action items + score small models
  judge.py report OUT_DIR                             # print aggregate tables (no private text)
  judge.py actions OUT_DIR EXTRACTION_JSON [JSONL ...] # action items vs Granola's next steps

Set LIDIA_USER_NAME to the note-taker's name as it appears in the meetings
(default "the user"). Requires ANTHROPIC_API_KEY. Spend is tracked in OUT_DIR/spend.json and capped by
JUDGE_BUDGET_USD (default 4.5).
"""
import collections
import json
import os
import random
import re
import sqlite3
import sys

import anthropic

MODEL = "claude-opus-5-5"
# $ per million tokens (claude-opus-5-5, 2026-10 price list).
PRICE_IN, PRICE_OUT, PRICE_CACHE_WRITE, PRICE_CACHE_READ = 4.0, 20.0, 5.0, 0.20
BUDGET = float(os.environ.get("JUDGE_BUDGET_USD", "4.5"))
# Who "Me" and "I" are in the notes being judged.
USER_NAME = os.environ.get("LIDIA_USER_NAME", "the user")
USER_FIRST_NAME = USER_NAME.split()[0] if USER_NAME != "the user" else USER_NAME

client = anthropic.Anthropic()


# ---------------------------------------------------------------- spend

def spend_path(out):
    return os.path.join(out, "spend.json")


def load_spend(out):
    try:
        with open(spend_path(out)) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"usd": 0.0, "calls": 0}


def record_spend(out, usage):
    s = load_spend(out)
    cost = (
        usage.input_tokens * PRICE_IN
        + usage.output_tokens * PRICE_OUT
        + (getattr(usage, "cache_creation_input_tokens", 0) or 0) * PRICE_CACHE_WRITE
        + (getattr(usage, "cache_read_input_tokens", 0) or 0) * PRICE_CACHE_READ
    ) / 1_000_000
    s["usd"] += cost
    s["calls"] += 1
    with open(spend_path(out), "w") as f:
        json.dump(s, f)
    return s["usd"]


def call_json(out, system, content, schema, max_tokens=12000):
    if load_spend(out)["usd"] > BUDGET:
        raise SystemExit(f"Judge budget of ${BUDGET} reached; stopping.")
    response = client.messages.create(
        model=MODEL,
        max_tokens=max_tokens,
        system=system,
        messages=[{"role": "user", "content": content}],
        output_config={"effort": "low", "format": {"type": "json_schema", "schema": schema}},
    )
    total = record_spend(out, response.usage)
    if response.stop_reason == "refusal":
        raise RuntimeError("judge refused")
    text = next(b.text for b in response.content if b.type == "text")
    print(f"  judge call ok (spent so far ${total:.2f})", flush=True)
    return json.loads(text)


# ---------------------------------------------------------------- data

def db_rows(db, pks):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = {}
    for pk in pks:
        r = con.execute("select ZTITLE, ZREFINEDTRANSCRIPT, ZSUMMARY from ZMEETING where Z_PK=?", (pk,)).fetchone()
        if r:
            rows[pk] = {"title": r[0] or "", "transcript": r[1] or "", "granola": r[2] or ""}
    return rows


def load_jsonl(paths):
    records = []
    for p in paths:
        with open(p) as f:
            records += [json.loads(line) for line in f if line.strip()]
    return records


# ---------------------------------------------------------------- overlap metric

STOP = set("""a an the and or of to in on for with at by from is are was were be been it this that
these those as we i you he she they our your their not no yes so if then than but also will would
can could should just about into over under more most very de la el y en que los las un una por
para con es se del al lo""".split())


def words(text):
    return [w for w in re.findall(r"[a-záéíóúñü0-9]+", text.lower()) if w not in STOP and len(w) > 1]


def f1(candidate, reference, n=1):
    def grams(ws):
        return collections.Counter(tuple(ws[i:i + n]) for i in range(len(ws) - n + 1))
    c, r = grams(words(candidate)), grams(words(reference))
    overlap = sum((c & r).values())
    if not c or not r or not overlap:
        return 0.0
    p, rec = overlap / sum(c.values()), overlap / sum(r.values())
    return 2 * p * rec / (p + rec)


# ---------------------------------------------------------------- key points

KEYPOINTS_SCHEMA = {
    "type": "object",
    "properties": {
        "key_points": {"type": "array", "items": {"type": "string"}},
        "decisions": {"type": "array", "items": {"type": "string"}},
        "next_steps": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["key_points", "decisions", "next_steps"],
    "additionalProperties": False,
}


def keypoints(db, out, pks):
    rows = db_rows(db, pks)
    path = os.path.join(out, "keypoints.json")
    existing = json.load(open(path)) if os.path.exists(path) else {}
    for pk, row in rows.items():
        if str(pk) in existing:
            continue
        print(f"key points for meeting {pk}", flush=True)
        existing[str(pk)] = call_json(
            out,
            "You turn reference meeting notes into an answer key for grading other summaries.",
            "From these reference meeting notes, list:\n"
            "- key_points: the 8-15 most important specific facts (numbers, names, systems, positions), one short sentence each\n"
            "- decisions: decisions that were made (may be empty)\n"
            "- next_steps: commitments, each with its owner if stated (may be empty)\n\n"
            f"<reference_notes>\n{row['granola']}\n</reference_notes>",
            KEYPOINTS_SCHEMA,
            max_tokens=6000,
        )
        json.dump(existing, open(path, "w"), indent=1)


# ---------------------------------------------------------------- scoring

SCORE_SCHEMA = {
    "type": "object",
    "properties": {
        "candidates": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "key_points_covered": {"type": "integer"},
                    "decisions_covered": {"type": "integer"},
                    "next_steps_covered": {"type": "integer"},
                    "hallucinations_major": {"type": "integer"},
                    "hallucinations_minor": {"type": "integer"},
                    "structure": {"type": "integer"},
                    "overall": {"type": "integer"},
                    "main_gap": {"type": "string"},
                },
                "required": ["label", "key_points_covered", "decisions_covered", "next_steps_covered",
                             "hallucinations_major", "hallucinations_minor", "structure", "overall", "main_gap"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["candidates"],
    "additionalProperties": False,
}

JUDGE_SYSTEM = """You grade AI-written meeting notes. You get the meeting transcript (from speech recognition, so expect transcription errors), an answer key of key points, decisions and next steps, and several candidate notes labelled with letters. Grade each candidate independently and strictly:
- key_points_covered / decisions_covered / next_steps_covered: how many answer-key items the candidate clearly states (paraphrase is fine; vague mentions don't count).
- hallucinations_major: claims that contradict the transcript or invent a decision, owner, number or date. hallucinations_minor: small unsupported details or wrong attributions that don't change the meaning. Fixing obvious speech-recognition spelling is not a hallucination.
- structure: 1-10, how easy the notes are to scan and act on (clear topic headings, terse specific bullets, a usable next-steps list, no padding).
- overall: 1-10, how useful the notes are to someone who missed the meeting, weighing coverage and accuracy most.
- main_gap: at most 12 words naming the biggest weakness. Do not quote the transcript."""


def score(db, out, label, jsonl_paths):
    keys = json.load(open(os.path.join(out, "keypoints.json")))
    records = [r for r in load_jsonl(jsonl_paths) if r.get("label") == label and not r.get("error")]
    by_meeting = collections.defaultdict(list)
    for r in records:
        by_meeting[r["meeting"]].append(r)
    rows = db_rows(db, list(by_meeting))
    results_path = os.path.join(out, f"scores_{label}.json")
    results = json.load(open(results_path)) if os.path.exists(results_path) else {}

    for pk, recs in sorted(by_meeting.items()):
        if str(pk) in results or str(pk) not in keys:
            continue
        row = rows[pk]
        cands = [("granola", row["granola"])] + [(r["model"], r["markdown"]) for r in recs]
        rng = random.Random(pk)
        rng.shuffle(cands)
        labels = {chr(65 + i): name for i, (name, _) in enumerate(cands)}
        key = keys[str(pk)]
        answer_key = (
            "KEY POINTS:\n" + "\n".join(f"{i+1}. {p}" for i, p in enumerate(key["key_points"]))
            + "\n\nDECISIONS:\n" + "\n".join(f"- {d}" for d in key["decisions"])
            + "\n\nNEXT STEPS:\n" + "\n".join(f"- {s}" for s in key["next_steps"])
        )
        content = [
            {"type": "text", "text": f"<transcript>\n{row['transcript']}\n</transcript>",
             "cache_control": {"type": "ephemeral"}},
            {"type": "text", "text": f"<answer_key>\n{answer_key}\n</answer_key>\n\n"
             + "\n\n".join(f"<candidate label=\"{chr(65+i)}\">\n{text}\n</candidate>" for i, (_, text) in enumerate(cands))
             + f"\n\nGrade all {len(cands)} candidates."},
        ]
        print(f"scoring meeting {pk} ({len(cands)} candidates)", flush=True)
        graded = call_json(out, JUDGE_SYSTEM, content, SCORE_SCHEMA)
        entry = {}
        for g in graded["candidates"]:
            name = labels.get(g["label"])
            if not name:
                continue
            text = dict(cands)[name]
            g.update({
                "rouge1_f": round(f1(text, row["granola"], 1), 3),
                "rouge2_f": round(f1(text, row["granola"], 2), 3),
                "words": len(text.split()),
                "n_key_points": len(key["key_points"]),
                "n_decisions": len(key["decisions"]),
                "n_next_steps": len(key["next_steps"]),
            })
            entry[name] = g
        results[str(pk)] = entry
        json.dump(results, open(results_path, "w"), indent=1)


# ---------------------------------------------------------------- routing ("decision model")

ROUTING_SCHEMA = {
    "type": "object",
    "properties": {
        "labels": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "owner_is_user": {"type": "boolean"},
                    "destination": {"type": "string", "enum": ["reminder", "clickup", "notion", "n8n", "none"]},
                    "deadline": {"type": ["string", "null"]},
                },
                "required": ["id", "owner_is_user", "destination", "deadline"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["labels"],
    "additionalProperties": False,
}


def routing(items_path, answers_path, out):
    items = json.load(open(items_path))
    labels_path = os.path.join(out, "routing_labels.json")
    if not os.path.exists(labels_path):
        sys.path.insert(0, os.path.dirname(__file__))
        rules = (open(os.path.join(os.path.dirname(__file__), "routing_rules.txt")).read()
                 .replace("{user_name}", USER_NAME).replace("{user_first_name}", USER_FIRST_NAME))
        listing = "\n".join(f"{it['id']} | {it['meeting_title']} | {it['text']}" for it in items)
        labelled = call_json(out, "You label action items for an evaluation set. Follow the rules exactly.",
                             f"{rules}\n\nItems (id | meeting | item):\n{listing}", ROUTING_SCHEMA, max_tokens=8000)
        json.dump(labelled, open(labels_path, "w"), indent=1)
    gold = {l["id"]: l for l in json.load(open(labels_path))["labels"]}
    if not os.path.exists(answers_path):
        print(f"labelled {len(gold)} items; no answers to score yet")
        return
    answers = json.load(open(answers_path))
    per_model = collections.defaultdict(lambda: collections.Counter())
    seconds = collections.defaultdict(list)
    for a in answers:
        g = gold.get(a["id"])
        if not g:
            continue
        m = per_model[a["model"]]
        seconds[a["model"]].append(a["seconds"])
        m["n"] += 1
        parsed = parse_routing(a["raw"])
        if parsed is None:
            m["invalid"] += 1
            continue
        m["destination"] += parsed["destination"] == g["destination"]
        m["owner"] += bool(parsed.get("owner_is_user")) == g["owner_is_user"]
        gd, pd = g["deadline"], parsed.get("deadline")
        m["deadline"] += (gd is None and pd in (None, "", "null")) or (gd is not None and pd not in (None, "", "null"))
    report = {}
    for model, m in per_model.items():
        n = m["n"]
        report[model] = {
            "n": n, "invalid": m["invalid"],
            "destination_acc": round(m["destination"] / n, 3),
            "owner_acc": round(m["owner"] / n, 3),
            "deadline_presence_acc": round(m["deadline"] / n, 3),
            "avg_seconds": round(sum(seconds[model]) / len(seconds[model]), 2),
        }
    dist = collections.Counter(g["destination"] for g in gold.values())
    report["_gold_destinations"] = dict(dist)
    json.dump(report, open(os.path.join(out, "routing_report.json"), "w"), indent=1)
    print(json.dumps(report, indent=1))


def parse_routing(raw):
    text = re.sub(r"```(json)?", "", raw).strip()
    s, e = text.find("{"), text.rfind("}")
    if s < 0 or e < s:
        return None
    try:
        obj = json.loads(text[s:e + 1])
    except json.JSONDecodeError:
        return None
    if obj.get("destination") not in ("reminder", "clickup", "notion", "n8n", "none"):
        return None
    return obj


# ---------------------------------------------------------------- action items vs Granola

ACTIONS_SCHEMA = {
    "type": "object",
    "properties": {
        "candidates": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "matched": {"type": "integer"},
                    "owner_correct": {"type": "integer"},
                },
                "required": ["label", "matched", "owner_correct"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["candidates"],
    "additionalProperties": False,
}


def actions(out, extraction_path, jsonl_paths):
    """Precision/recall of action items against Granola's next steps (answer key).

    Candidates: the dedicated extraction pass (`action_extraction.json`) and the
    "Next Steps" parsed from each summary run. No transcript is sent.
    """
    keys = json.load(open(os.path.join(out, "keypoints.json")))
    cands = collections.defaultdict(dict)  # pk -> name -> [items]
    flags = collections.defaultdict(dict)  # pk -> name -> has_action_items
    seconds = collections.defaultdict(list)
    peaks = collections.defaultdict(list)
    for a in json.load(open(extraction_path)):
        name = "dedicated:" + a["model"].split("/")[-1]
        parsed = None
        text = re.sub(r"```(json)?", "", a["raw"]).strip()
        s, e = text.find("{"), text.rfind("}")
        try:
            parsed = json.loads(text[s:e + 1]) if s >= 0 else None
        except json.JSONDecodeError:
            parsed = None
        items = []
        if parsed:
            flags[a["meeting"]][name] = bool(parsed.get("has_action_items"))
            for it in parsed.get("items") or []:
                items.append(f"{it.get('owner') or '-'}: {it.get('title')} ({it.get('deadline') or '-'})")
        cands[a["meeting"]][name] = items
        seconds[name].append(a["seconds"])
        peaks[name].append(a["peakGB"])
    for r in load_jsonl(jsonl_paths):
        if r.get("error"):
            continue
        name = f"{r['label']}-summary:" + r["model"].split("/")[-1]
        cands[r["meeting"]][name] = r["nextSteps"]
    path = os.path.join(out, "actions_scores.json")
    results = json.load(open(path)) if os.path.exists(path) else {}
    for pk, by_name in sorted(cands.items()):
        if str(pk) in results or str(pk) not in keys:
            continue
        gold = keys[str(pk)]["next_steps"]
        names = sorted(by_name)
        listing = "\n\n".join(
            f"<candidate label=\"{chr(65+i)}\">\n" + ("\n".join(f"- {x}" for x in by_name[n]) or "(none)") + "\n</candidate>"
            for i, n in enumerate(names))
        content = ("<answer_key>\n" + "\n".join(f"{i+1}. {g}" for i, g in enumerate(gold)) + "\n</answer_key>\n\n" + listing +
                   "\n\nFor each candidate list: matched = how many answer-key items it contains (same task, paraphrase ok; "
                   "count each key item at most once); owner_correct = how many of those matched items name the same owner "
                   f"as the key (\"Me\" = {USER_FIRST_NAME}).")
        print(f"actions meeting {pk} ({len(names)} lists)", flush=True)
        graded = call_json(out, "You grade extracted action items against an answer key.", content, ACTIONS_SCHEMA, max_tokens=4000)
        entry = {}
        for g in graded["candidates"]:
            idx = ord(g["label"]) - 65
            if 0 <= idx < len(names):
                n = names[idx]
                entry[n] = {"matched": g["matched"], "owner_correct": g["owner_correct"],
                            "predicted": len(by_name[n]), "gold": len(gold),
                            "flag": flags[pk].get(n)}
        results[str(pk)] = entry
        json.dump(results, open(path, "w"), indent=1)
    agg = collections.defaultdict(lambda: collections.Counter())
    for pk, entry in results.items():
        for n, g in entry.items():
            a = agg[n]
            a["matched"] += min(g["matched"], g["predicted"], g["gold"])
            a["owner"] += g["owner_correct"]
            a["predicted"] += g["predicted"]
            a["gold"] += g["gold"]
            if g["flag"] is not None:
                a["flag_n"] += 1
                a["flag_ok"] += g["flag"] == (g["gold"] > 0)
    print("candidate | precision | recall | owner correct | has-items accuracy | avg s | peak GB")
    for n, a in sorted(agg.items(), key=lambda kv: -kv[1]["matched"]):
        p = a["matched"] / max(1, a["predicted"])
        r = a["matched"] / max(1, a["gold"])
        flag = f"{a['flag_ok']}/{a['flag_n']}" if a["flag_n"] else "-"
        sec = f"{sum(seconds[n])/len(seconds[n]):.1f}" if seconds.get(n) else "-"
        pk_ = f"{max(peaks[n]):.1f}" if peaks.get(n) else "-"
        print(f"{n} | {p:.0%} | {r:.0%} | {a['owner']}/{a['matched']} | {flag} | {sec} | {pk_}")
    print(f"\nJudge spend: ${load_spend(out)['usd']:.2f}")


# ---------------------------------------------------------------- report

def report(out):
    for name in sorted(os.listdir(out)):
        if not name.startswith("scores_"):
            continue
        data = json.load(open(os.path.join(out, name)))
        agg = collections.defaultdict(lambda: collections.defaultdict(list))
        for pk, entry in data.items():
            for model, g in entry.items():
                a = agg[model]
                a["kp"].append(g["key_points_covered"] / max(1, g["n_key_points"]))
                if g["n_decisions"] + g["n_next_steps"]:
                    a["dn"].append((g["decisions_covered"] + g["next_steps_covered"]) / (g["n_decisions"] + g["n_next_steps"]))
                a["major"].append(g["hallucinations_major"])
                a["minor"].append(g["hallucinations_minor"])
                a["structure"].append(g["structure"])
                a["overall"].append(g["overall"])
                a["r1"].append(g["rouge1_f"])
                a["words"].append(g["words"])
        print(f"\n== {name} ({len(data)} meetings)")
        print("model | key pts | decisions+next | major halluc/mtg | minor/mtg | structure | overall | ROUGE-1 F | words")
        mean = lambda xs: sum(xs) / len(xs) if xs else float("nan")
        for model, a in sorted(agg.items(), key=lambda kv: -mean(kv[1]["overall"])):
            print(f"{model} | {mean(a['kp']):.0%} | {mean(a['dn']):.0%} | {mean(a['major']):.2f} | {mean(a['minor']):.2f} | "
                  f"{mean(a['structure']):.1f} | {mean(a['overall']):.1f} | {mean(a['r1']):.2f} | {mean(a['words']):.0f}")
    print(f"\nJudge spend: ${load_spend(out)['usd']:.2f} over {load_spend(out)['calls']} calls")


if __name__ == "__main__":
    cmd = sys.argv[1]
    out_arg = {"keypoints": 3, "score": 3, "routing": 4, "report": 2, "actions": 2}.get(cmd)
    if out_arg:
        os.makedirs(sys.argv[out_arg], exist_ok=True)
    if cmd == "keypoints":
        keypoints(sys.argv[2], sys.argv[3], [int(x) for x in sys.argv[4:]])
    elif cmd == "score":
        score(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:])
    elif cmd == "routing":
        routing(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "report":
        report(sys.argv[2])
    elif cmd == "actions":
        actions(sys.argv[2], sys.argv[3], sys.argv[4:])
    else:
        raise SystemExit(__doc__)
