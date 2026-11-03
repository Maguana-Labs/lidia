# Summary benchmark: local models vs Granola on the owner's meetings

**Date:** 2026-11-03
**Machine:** MacBook Pro M3 Max (30-core GPU), 36 GB, macOS 27.2. The machine was in normal use during the runs: a recording LidIA build, Granola, Xcode builds from other agents, and a GPU often at about 80% busy before the benchmark started. Speeds are therefore pessimistic and noisy. The same model varied up to 2× between runs; see §2.3.
**Scope:** Owner's asks 1–5: the Qwen catalogue, streaming summaries, this benchmark, prep history and the "decision model". Code changes are on branch `worktree-agent-ae9657c03f7f0bb5f`.

Transcripts are private. This document has no transcript text and only aggregate scores. Raw outputs stay in the session scratchpad, not in the repo.

---

## TL;DR

1. **Default local model: Qwen 3.5 4B** (`mlx-community/Qwen3.5-4B-4bit`, 3.06 GB) on every Mac below 48 GB. It is the lightweight default and the best measured trade-off at that size:
   - Text appears after **6–22 s** for a 20–45 minute meeting (4–11K tokens).
   - A full summary takes **11–33 s** in the quiet v3 run.
   - **Qwen 3.6 35B-A3B** writes the best local notes (judge 6.4/10 vs 4.7 for 4B). It is the pick **from 48 GB**: it used **27 GB** on this 36 GB Mac and pushed the system into swap.
2. **Qwen beats Gemma here.** At similar size, Qwen 3.5 4B scored 4.7 against Gemma 4 E4B's 4.2. Gemma missed more, but it invented less. The 35B-A3B scored 6.4 and was the best of all local models.
3. **Granola is still clearly ahead.** Its notes are the answer key, so its coverage score is trivially 100%. Its accuracy and structure scores are independent, though: 0 major errors per meeting, against 1.4 for the best local model, and structure 8.8 against 7.6.
4. **Summaries now stream** as markdown through `ProcessingProgressCenter.appendSummaryText`. This covers MLX, Apple Intelligence, Claude, OpenAI-compatible providers and Ollama.
   - The LLM "refine transcript" pass is off by default. It used to rewrite the whole transcript before anything was shown.
   - On the owner's two failing Apple Intelligence meetings from today, text now appears after **1.7 s and 3.9 s**. Before, one failed with "Context length exceeded" and the other hung for more than an hour.
5. **Decision model: not wired.** Small local models route action items poorly:
   - Destinations were 23–58% correct against a 50% always-"none" baseline.
   - Whether the user owns the item was right 52–55% of the time.
   - LiquidAI LFM3-1.7B **cannot load** in mlx-swift-lm 3.32.3 (§5.3).
6. **Prep briefs** now match history by title series and parsed attendee emails. The Northwind meeting finds its 4 earlier meetings and is never called a first encounter.
7. **Claude API spend for judging: $3.82** of the $5 budget.

---

## 1. Models

### 1.1 Qwen family on mlx-community (checked 2026-11-03)

Each repo was checked for HTTP 200, size, pinned SHA and `model_type` through the Hugging Face API. Support was checked against the registered types in mlx-swift-lm 3.32.3 (`LLMModelFactory.swift`: `qwen3_5`, `qwen3_5_moe`, `qwen3_5_text`, …).

| Repo | Size | `model_type` | Loads in 3.32.3 | Catalogue |
|---|---|---|---|---|
| `mlx-community/Qwen3.5-0.8B-4bit` | 0.65 GB | qwen3_5 | yes | not added (too small for notes) |
| `mlx-community/Qwen3.5-2B-4bit` @ `674aaa7` | 1.75 GB | qwen3_5 | yes | **tested and rejected**: it invents facts (§2) |
| `mlx-community/Qwen3.5-4B-4bit` @ `0e7ffd5` | 3.06 GB | qwen3_5 | yes | **recommended below 48 GB** |
| `mlx-community/Qwen3.5-9B-4bit` @ `8b2b98c` | 5.98 GB | qwen3_5 | yes | alternate (16 GB+) |
| `mlx-community/Qwen3.6-35B-A3B-4bit` @ `38740b8` | 20.43 GB | qwen3_5_moe | yes | **recommended from 48 GB** |
| `mlx-community/Qwen3.8-27B-4bit` @ `10c35ca` | 16.08 GB | qwen3_5 | yes | alternate (48 GB+), **added, not benchmarked**: the download was stopped to protect the owner's memory |
| `mlx-community/Qwen3.6-27B-4bit`, `Qwen3.5-27B-4bit` | 16.08 GB | qwen3_5 | yes | not added: superseded by 3.8 27B |
| `mlx-community/Qwen3.8-Flash-Next-4bit` | 111.5 GB | qwen4_exp | **no** | not added |

**Context caps raised for Qwen.** Qwen 3.5 and 3.6 use hybrid attention: only 8 of 32 layers in the 4B keep a KV cache, about 32 KB per token. A one-hour meeting therefore fits in one pass:
- 4B: 16K → 32K
- 9B: 32K → 64K
- 35B-A3B: 128K

This removed map-reduce for every test meeting except the 31K-token one.

**Thinking off.** Every MLX request now sends `enable_thinking: false` through the chat template (`MLXLocalClient.templateContext`). The reasons:
- Qwen 3.6 and 3.8 think by default.
- LidIA strips reasoning before showing anything, so thinking only adds latency.
- Gemma 4 and the small Qwen 3.5 models ignore the flag.

### 1.2 Recommended model per RAM tier

| Mac memory | Pick | Why |
|---|---|---|
| 8 GB | Qwen 3.5 4B | 3 GB of weights, about 1 GB of KV cache at 32K |
| 16 GB | Qwen 3.5 4B | 9B adds coverage but made the most attribution errors (2.8 major per meeting) |
| 24 GB | Qwen 3.5 4B | same; Gemma 4 12B is listed but not benchmarked |
| 32–43 GB (this Mac) | Qwen 3.5 4B | 35B-A3B is better, but used 27 GB and caused swap on 36 GB |
| 48 GB+ | Qwen 3.6 35B-A3B | best local quality and fastest decode (55–73 tok/s on short meetings) |

**"Automatic (On-Device)"** now uses only this pick. It must be fully downloaded and verified:
- no partial blobs;
- tokenizer present;
- every shard in the index present;
- at least 95% of the expected bytes.

Otherwise it falls back to Apple Intelligence. Nothing else in the models folder is used silently. A user who picks a model under the MLX provider still gets that model, and it must verify too.

---

## 2. Benchmark

### 2.1 Method

**Data.** Nine meetings imported from Granola, read from a read-only copy of the library:
- 0.7K to 31K tokens (2 to about 90 minutes);
- English and Spanish;
- 1:1s, client calls, an internal review, a vet consult.

For each one, Granola's summary is the reference.

**Run.** `Tests/LidIATests/SummaryBenchmarkTests.swift` is gated by `LIDIA_BENCH=1` and was built in release. It runs LidIA's real streaming path, `MapReduceSummarizer.summarizeMarkdown` with the General template, then the facts step. It records:
- time to first visible token, from the start of the summary step;
- total time;
- generated tokens and decode and prefill tokens per second, from MLX's `GenerateCompletionInfo`.

**Judge.** `scripts/benchmark/judge.py`, using `claude-opus-5-5` at effort `low` with structured output.
1. Claude turns Granola's notes into an answer key for each meeting: 8–15 key facts, decisions, and next steps with owners.
2. One call per meeting grades all candidates blind, with Granola's own notes shuffled in among them. The judge sees the transcript, so it can count hallucinations:
   - key points, decisions and next steps covered;
   - major and minor hallucinations;
   - structure (1–10);
   - overall usefulness (1–10).

**Cross-check.** A ROUGE-1 F1 against Granola's notes, as a cheap overlap metric.

### 2.2 Results, prompt v1 (9 meetings, all models)

| Model | Key points | Decisions + next steps | Major errors per meeting | Minor errors per meeting | Structure | **Overall** | ROUGE-1 F | Words |
|---|---|---|---|---|---|---|---|---|
| Granola (reference, blind) | 100%* | 94%* | 0.00 | 0.22 | 8.8 | **9.0** | 1.00 | 567 |
| Qwen 3.6 35B-A3B | 70% | 49% | 1.44 | 2.22 | 7.6 | **6.4** | 0.43 | 493 |
| Qwen 3.5 9B | 66% | 43% | 2.78 | 3.22 | 6.3 | **5.1** | 0.42 | 602 |
| Qwen 3.5 4B | 56% | 34% | 2.22 | 2.67 | 6.2 | **4.7** | 0.35 | 385 |
| Gemma 4 E4B | 43% | 27% | 1.00 | 2.11 | 5.7 | **4.2** | 0.35 | 341 |
| Apple Intelligence (on-device, 6 meetings) | 46% | 42% | 3.00 | 3.50 | 3.7 | **3.5** | 0.40 | 554 |
| Qwen 3.5 2B | 20% | 10% | 4.33 | 2.78 | 3.9 | **1.4** | 0.27 | 302 |

\*The answer key comes from Granola's notes, so its coverage is trivially high. Its error and structure scores are comparable with the others.

**The judge's recurring complaints:**
- 2B invents content outright, such as budgets and pricing that nobody discussed. This is why it is out of the catalogue.
- 4B and 9B misattribute owners.
- Gemma E4B is vague: it covers less but invents little.
- Apple Intelligence produces fragmented and duplicated sections: its 4–8K context forces map-reduce.
- 35B-A3B mostly omits detail. Its next-steps lists are short.

### 2.3 Speed

These are decode and prefill rates from MLX itself. Times are for the summary step only.

| Model | Run | Time to first text (median) | Total (median) | Decode tok/s | Prefill tok/s | Peak memory |
|---|---|---|---|---|---|---|
| Qwen 3.5 4B | v3 (quietest) | **17.4 s** (6–22 s up to 11K tokens) | **26.6 s** | 58–74 | 690–955 | ≈4.4 GB |
| Qwen 3.5 4B | v2 | 25.2 s | 44.3 s | 22–60 | 410–640 | |
| Qwen 3.5 4B | v1 (heavy GPU contention) | 37.7 s | 74.4 s | 17–33 | 220–300 | |
| Qwen 3.5 2B | v1 | 8.3 s | 21.7 s | 42–92 | 740–1260 | ≈2.2 GB |
| Qwen 3.5 9B | v1 | 57.5 s | 93.5 s | 15–23 | 195–275 | |
| Gemma 4 E4B | v1 | 11.7 s | 38.0 s | 25–33 | 540–745 | |
| Qwen 3.6 35B-A3B | v2 | 31.5 s | 47.4 s | 30–65 | 120–680 | **27 GB** |
| Apple Intelligence | v1 (6 meetings, 1–4 parts) | not comparable (see note) | 109 s | n/a | n/a | system |

**How to read the speed table:**
- **Prefill dominates.** A 20K-token meeting on 4B spends about 40–60 s reading before it writes.
- The 35B-A3B's prefill fell to 120–160 tok/s past 11K tokens. That is memory pressure at 27 GB on a 36 GB Mac, not compute.
- Facts step (title and decisions, read from the finished summary): 1–13 s on 4B, median 3 s.
- Apple Intelligence: for map-reduce meetings, the time-to-first-text figure counted only the final pass. That was fixed afterwards (`requestStart` in `StreamingSummarizer`).

### 2.4 Prompt changes

| Version | Change | Qwen 3.5 4B overall | Major errors per meeting | Decisions + next steps |
|---|---|---|---|---|
| v1 | First markdown prompt: Granola-style topic headings, terse bullets, "Decided:", a "Next Steps" section with "Owner: task (deadline)" | **4.7** | **2.22** | 34% |
| v2 | Removed the concrete examples that 2B copied (budget, EU pricing); "list EVERY commitment and request"; stricter attribution | 3.4 | 3.44 | 43% |
| v3 | v2 without the "every commitment" push and without naming topics to avoid | 3.6 | 3.44 | 24% |

- v2 raised next-steps coverage (35B-A3B: 49% → 58%) but brought more invented or misassigned owners.
- v3 didn't recover.
- **v1 ships.** v2 and v3 are recorded here and were reverted.
- With 9 meetings and sampling at temperature 0.7, differences under about 1 point are within noise.
- **Next prompt experiment** (not run, to stay within budget and the owner's memory limits): a lower summary temperature (0.3) for Qwen.

---

## 3. Streaming design

```
transcript ─▶ [vocabulary fixes, no LLM] ─▶ summary prompt (markdown) ──stream──▶ appendSummaryText ─▶ UI
                                               │                                     (resetSummaryText on retry)
                                               ▼
                                   finished markdown ─▶ sections · "Decided:" · Next Steps (action items)
                                               │
                         facts step (JSON: title, decisions, fallback action items)
                         ├─ cloud: runs concurrently on the transcript while the summary streams
                         └─ local: runs after, on the short summary (MLX serialises generation anyway)
```

**What streams.** The visible summary is plain markdown, never JSON (`SummaryPrompts.markdownSystemPrompt`). The format mirrors Granola's: topic headings, terse nested bullets, then "### Next Steps" with "- Owner: task (deadline)". The streamed markdown is saved verbatim as `Meeting.summary`. `StructuredSummary` is parsed from it, and nested bullets are flattened for it.

**Where the structure comes from.**
- **Action items** come from Next Steps, so the list matches what the user read.
- **The title** comes from a small JSON facts step (`MeetingFactsExtractor`). It uses guided generation on Apple Intelligence.
- **Custom free-form templates** keep the old JSON path, because their prompt defines the output.

**Refine pass off.** The LLM refine pass (`refineWithLLM`, default false) rewrote the whole transcript before the summary could start.
- A one-hour meeting on 4B would spend about 2.5 minutes generating a copy of the transcript at the measured decode rate before showing anything. This is derived from the measured rates, not timed.
- On Apple Intelligence it turned 2.5K words into 7.7K.
- Custom vocabulary is applied with a regex instead (`VocabularyCorrector`).

**Budgets.**
- MLX budgets come from the model's catalogue context cap.
- Automatic mode was being treated as an unknown 4K client. It now resolves to its backend.
- Apple Intelligence uses `SystemLanguageModel.contextSize`.

**Bounds** (`PipelineLimits`):
- The summary step has a deadline of 10 min + 20 s per 1K tokens, at most 40 min.
- Facts and destination steps have 3 min each.
- At most 24 map calls per summary.
- "Context length exceeded" is retried once with half the input budget.
- A cleanup result longer than 1.6× its input is rejected.
- On timeout, the meeting fails with a clear message and keeps its transcript.

**Apple Intelligence:**
- The answer length is capped (`maximumResponseTokens`) and the schema has room reserved in the context.
- Stream deltas are computed on UTF-8 offsets. The old O(n²) snapshot diff explains the 100% CPU.

**Claude effort:** `medium` for the summary, streamed or not. `low` for the facts step, map notes and prep.

**MLX safety.** Every MLX generation goes through one process-wide `MLXInferenceLock`. The lock is held until the generation task has finished. This fixes the `MTLReleaseAssertionFailure` crash seen when a summary and another request encoded at once.

### Before and after

| Case | Before | After |
|---|---|---|
| Owner's 08:00 meeting (186 words, Apple Intelligence) | failed: "Context length exceeded" | first text 1.7 s, done 8 s |
| Owner's 08:03 meeting (2,498 words, Apple Intelligence) | stuck in "processing" for over an hour at 100% CPU | first text 3.9 s, done 36 s |
| 20–45 min meeting (4–11K tokens), Qwen 3.5 4B (MLX) | nothing visible until refine + JSON finished (estimated 2–4 min) | first text after 6–22 s, done after 11–33 s (v3 run) |

The Apple Intelligence "after" timings come from `runPipelineOnRecordedMeetings`, which runs the full `MeetingPipeline` on the stored raw words.

---

## 4. Prep briefs and history

**Bug.** "Northwind x Harborcloud – SaaS Platform on AWS" got "This appears to be a first-encounter meeting". There were two causes:
- History was matched on exact attendee strings.
- Granola imports before 074354b stored all participants as one string, e.g. "Alex Moreno <daniel.r@northwind.example>".

**Fix.** `Proactive/MeetingHistoryMatcher.swift` combines four signals:
- the same recurring calendar series;
- the same or a similar title, with dates and numbering ignored;
- shared email addresses, parsed out of any attendee format;
- a weak same-company signal that needs a partly similar title.

The user's own address never counts. It is inferred as names present in most meetings, plus emails whose local part is that name. Own-company colleagues count less than external guests.

**Brief.** `Proactive/PrepBrief.swift` puts the three most recent summaries and up to 10 open action items into the prompt. When history exists, the prompt says the meeting is not a first meeting. Old "first-encounter" briefs are regenerated once history is found.

**Tests.** `Tests/LidIATests/PrepHistoryTests.swift` uses an in-memory container and covers:
- the owner's case: four Northwind meetings found, internal meetings excluded;
- title-only series;
- the user's own address;
- Google recurring IDs;
- future meetings.

---

## 5. Decision model (action routing)

### 5.1 Routing each action item

**Set.** 88 action items from Granola's Next Steps sections across the owner's 20 imported meetings. Claude labelled each one with three fields:
- `owner_is_user`;
- destination: reminder, clickup, notion, n8n or none;
- deadline.

**Gold distribution.** none 44, reminder 22, clickup 16, notion 5, n8n 1. Each model used LidIA's `ActionRouting` prompt.

| Model | Destination accuracy | User-owns-it accuracy | Deadline present/absent | Latency per item |
|---|---|---|---|---|
| Qwen 3.5 2B | 23% | 52% | 94% | 0.38 s |
| Qwen 3.5 4B | 58% | 55% | 95% | 0.75 s |
| Apple Intelligence | 43% | 53% | 72% | 1.01 s |
| *Always "none"* | *50%* | *52%* | | |

Ownership is at chance level: the small models can't tell when "Alex" means the user.

### 5.2 Extracting action items: dedicated pass vs the summary's Next Steps

The answer key is Granola's next steps for the 9 benchmark meetings. Claude counted matches; no transcript was sent for this step.

| Approach | Precision | Recall | Owner right when matched | "Has action items" correct | Latency | Peak memory |
|---|---|---|---|---|---|---|
| Summary Next Steps, Qwen 3.6 35B-A3B | 88% | 39% | 19/21 | | (in summary) | |
| Dedicated pass, Qwen 3.5 4B (`ActionRouting.extractionPrompt`) | 84% | 30% | 13/16 | 7/8 | 35.8 s | 4.4 GB |
| Summary Next Steps, Apple Intelligence | 57% | 34% | 5/13 | | | |
| Summary Next Steps, Qwen 3.5 9B | 65% | 31% | 8/17 | | | |
| Summary Next Steps, Gemma 4 E4B | 61% | 26% | 5/14 | | | |
| **Summary Next Steps, Qwen 3.5 4B (current approach)** | 73% | 15% | 7/8 | | 0 s extra | |
| Dedicated pass, Qwen 3.5 2B | 21% | 13% | 2/7 | 9/9 | 12.1 s | 2.2 GB |

### 5.3 LiquidAI LFM3-1.7B

**Builds.** `LiquidAI/LFM3-1.7B-MLX-6bit` @ `df8c477` is 1.42 GB, and `LiquidAI/LFM3-1.7B-MLX-4bit` @ `deb2986` is 0.99 GB. Both are `model_type: lfm3` (`Lfm3ForCausalLM`).

**Architecture.** 24 layers: 12 gated short-conv layers (`conv_L_cache` 7), 6 sliding-window attention layers (window 256, rope θ 1e4) and 6 global-attention layers (partial rotary 0.5, θ 1e6). Each has 16 heads and 4 KV heads, with a 256K context.

**It does not load in mlx-swift-lm 3.32.3.**
- 3.32.3 registers only `lfm2` and `lfm2_moe` (`LLMModelFactory.swift:96,105`). There is no `lfm3` type.
- Support exists only in open, unmerged pull requests:
  - `ml-explore/mlx-swift-lm` #750 and #756, both opened 2026-11-03;
  - `ml-explore/mlx-lm` #2016 for Python.
- These PRs are written against post-3.32.3 `main`. They use `ModelCheckpoint`, `prepareCheckpoint` and `validate(tokenizer:)`, which don't exist in 3.32.3, and they add about 660 lines of model code in `MLXLMCommon/Models/LFM3.swift` and `MLXLLM/Models/LFM3.swift`.

**What it would take.** Wait for #756 or #750 to merge and ship in a tagged release, then move the pin. That move needs mlx-swift and mlx-audio-swift compatibility re-checked, because the mlx-audio-swift pin depends on mlx-swift 0.32. The alternative is to port LFM3 onto 3.32.3's LFM2 code and register it from the app (`LLMTypeRegistry.registerModelType("lfm3", …)`), with numerical checks against the reference outputs in #756.

**Not measured.** I didn't run the PR branch or Liquid's tooling: unmerged third-party code. So there are no LFM3 numbers. The comparison above uses Qwen 3.5 2B and 4B, the smallest Qwen sizes.

**License.** LFM Open License v1.0. Section 5(a): "The rights granted under this License for Commercial Use are conditioned upon You or Your Legal Entity not exceeding the Threshold." The Threshold is "annual revenue of 10 million United States dollars ($10,000,000) or more". Section 5(b) excludes commercial use above that threshold. It is not Apache 2.0, so shipping it needs a licence review.

Related: `mlx-community/Qwen3.5-0.8B-decision` is a "typed decisions" adapter with a custom head, served by `optiq` (accuracy 0.77 on its own four workflows). It needs that server, not mlx-swift-lm, so it isn't usable in-app either.

### 5.4 Verdict

**Not wired.** No small local model routes action items reliably enough to fire automations:
- destination at 58% at best, against a 50% baseline;
- ownership at chance level.

**What could change this.**
- The dedicated 4B extraction pass doubles recall over 4B's own Next Steps (30% vs 15%) at higher precision (84% vs 73%). It also costs about 36 s of GPU time after every meeting, and on MLX it queues behind the summary.
- The better fix is a better summary model: 35B-A3B's Next Steps reached 88% precision and 39% recall at no extra cost. For now, `detectDestinations` keeps suggesting destinations only.
- Revisit LFM3-1.7B once mlx-swift-lm ships `lfm3`. Its tool-calling post-training is the right shape for this.

**Automations must stay confirm-before-send:**
- the proposal is a suggestion the user approves;
- nothing fires on a local model's say-so;
- the user's identity should be passed to the prompt, a setting LidIA doesn't have yet. That alone would fix most owner errors.

---

## 6. Embeddings (evaluation only)

| Option | Runs on this stack? | Size | Notes |
|---|---|---|---|
| **EmbeddingGemma 2** via mlx-swift-lm `MLXEmbedders` | **No.** 3.32.3 registers `gemma3`, `gemma3_text`, `gemma3n`, `qwen3`, bert and nomic-bert; `mlx-community/embeddinggemma-2-4bit` is `model_type: embedding_gemma2` | 1.13 GB (bundles audio and vision towers) | Needs new MLXEmbedders support |
| **EmbeddingGemma 2** via Core ML (`FluidInference/embeddinggemma-2-coreml` @ `3f978dd`) | **Yes.** `EmbeddingGemma2Text.mlpackage` runs fully on the Neural Engine | 277 MB of text weights (fp16) | Fixed-shape inputs up to 512 tokens. 768-dimension output, Matryoshka down to 512/256/128 by truncation and re-normalising. The card reports 2.6 ms at 32 tokens and 27 ms at 512 tokens on M5 Pro. Same org as FluidAudio, which LidIA already ships. Apache 2.0 on Hugging Face (`google/embeddinggemma-2` card) |
| Apple `NLContextualEmbedding` | Yes, built in | 0 MB download (system assets) | Per-language models and a fixed dimension; no Matryoshka; lower retrieval quality than a dedicated embedder; no extra memory |

**Recommendation for the semantic-memory work.** Use the Core ML text package of EmbeddingGemma 2 at 256 dimensions, with chunks of 512 tokens or fewer. That is the same model Google's AI Edge Foresight uses, and it stays off the GPU, so it never contends with MLX summaries. Keep `NLContextualEmbedding` as the no-download fallback. This was not benchmarked here.

---

## 7. Reproducing

1. **Copy the library first.** Never open the live store for writing:
   ```
   sqlite3 "file:$HOME/Library/Application Support/LidIA/LidIA.store?mode=ro" ".backup /tmp/copy.store"
   ```
2. **Download models into a benchmark-only folder,** never `~/Library/Application Support/LidIA/Models`. The test refuses the app folder.
3. **Build and point MLX at the metallib:**
   ```
   swift build -c release --build-tests -Xswiftc -enable-testing -Xswiftc -DDEBUG
   ```
   Then copy `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` next to the test binary as `mlx.metallib`, and remove it before the next build.
4. **Run the benchmark:**
   ```
   LIDIA_BENCH=1 LIDIA_BENCH_MODELS_DIR=… LIDIA_BENCH_DB=… LIDIA_BENCH_MEETINGS=20,12,… \
   LIDIA_BENCH_MODELS=mlx-community/Qwen3.5-4B-4bit LIDIA_BENCH_OUT=… LIDIA_BENCH_LABEL=v1 \
   swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --skip-build --filter runSummaryBenchmark
   ```
   - `LIDIA_ACTIONS=1 --filter runActionExtraction` runs the dedicated extraction pass.
   - `LIDIA_ROUTING_ITEMS=… --filter runRoutingBenchmark` runs routing.
   - `LIDIA_PIPELINE_PKS=… --filter runPipelineOnRecordedMeetings` runs the full pipeline on recorded meetings.
5. **Judge:**
   ```
   python3 scripts/benchmark/judge.py keypoints|score|actions|routing|report …
   ```
   Spend is capped by `JUDGE_BUDGET_USD`.
6. **On a 36 GB Mac,** run one model at a time and nothing above the 4B class while the owner is working.
