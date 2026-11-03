#!/usr/bin/env python3
"""Switch LidIA's Siri AI Developer Preview pieces on or off.

The Siri AI pieces (`@AppIntent(.tool)`, `@AppEntity(.generable)`, property
descriptions, per-property authentication and visibility, app skills) need the
Xcode 27.3 SDK. Until then they live where today's build can't see them:

* `// siri-27.3:` marker comments next to the code they change, in
  Sources/LidIA, Packages/LidIAKit/Sources and LidIAiOS/{Sources,Shared}:
    - a line `// siri-27.3: <code>` inserts <code> when enabled (indent the
      marker as the code should be indented, never the code after the marker);
    - `<code> // siri-27.3: <replacement>` replaces <code> when enabled
      (the original is kept as `// siri-27.2: <code>` so `off` restores it).
* Siri/Staged-27.3/: whole files (the generable MeetingSearchRequest) and the
  Skills.skillsbundle with the SKILL.md files.

Commands:
  status    what's on, and how many markers each file has
  check     validate the skills, check that the switched-on code parses, probe the SDK
  on        switch everything on (refuses unless the SDK probe passes; --force skips it)
  off       switch everything off again (the exact inverse of on)

See docs/siri.md for the full switch-on steps.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGED = os.path.join(ROOT, "Siri", "Staged-27.3")
SCAN_DIRS = ["Sources/LidIA", "Packages/LidIAKit/Sources", "LidIAiOS/Sources", "LidIAiOS/Shared"]
STAGED_SWIFT_DEST = os.path.join(ROOT, "Packages/LidIAKit/Sources/LidIAAppIntents/Staged")
IOS_SKILLS_DEST = os.path.join(ROOT, "LidIAiOS/Sources/Skills.skillsbundle")
# The iPhone has no Draft Follow-Up or Prepare Next Step, so no skill built on them.
IOS_SKILLS = ["meeting-follow-up", "prep-for-meeting", "catch-up", "live-meeting"]
SKILL_BODY_LIMIT = 10_000

INSERT_OFF = re.compile(r"^(\s*)// siri-27\.3: (.*)$")
INSERT_ON = re.compile(r"^(\s*)(.*\S) // siri-27\.3$")
REPLACE_OFF = re.compile(r"^(\s*)(\S.*?) // siri-27\.3: (.*)$")
REPLACE_ON = re.compile(r"^(\s*)(\S.*?) // siri-27\.2: (.*)$")

PROBE = """
import AppIntents

@AppIntent(.tool)
struct ProbeToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Probe"
    func perform() async throws -> some IntentResult { .result() }
}

@AppEntity(.generable)
struct ProbeGenerable: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Probe"
    @Property(title: "Name", description: "A name.", authenticationPolicy: .requiresAuthentication)
    var name: String?
    @Property(title: "Secret", visibility: .internal)
    var secret: String?
    var displayRepresentation: DisplayRepresentation { "Probe" }
    init() {}
}
"""


def swift_files():
    for rel in SCAN_DIRS:
        base = os.path.join(ROOT, rel)
        for dirpath, _, names in os.walk(base):
            for name in sorted(names):
                if name.endswith(".swift"):
                    yield os.path.join(dirpath, name)


def transform(text, enable):
    """Returns (new text, number of marker lines changed)."""
    out, changed = [], 0
    for line in text.split("\n"):
        new = line
        if enable:
            m = INSERT_OFF.match(line)
            if m:
                new = f"{m.group(1)}{m.group(2)} // siri-27.3"
            else:
                m = REPLACE_OFF.match(line)
                if m:
                    new = f"{m.group(1)}{m.group(3)} // siri-27.2: {m.group(2)}"
        else:
            m = REPLACE_ON.match(line)
            if m:
                new = f"{m.group(1)}{m.group(3)} // siri-27.3: {m.group(2)}"
            else:
                m = INSERT_ON.match(line)
                if m:
                    new = f"{m.group(1)}// siri-27.3: {m.group(2)}"
        if new != line:
            changed += 1
        out.append(new)
    return "\n".join(out), changed


def counts(text):
    off = sum(1 for l in text.split("\n") if INSERT_OFF.match(l) or REPLACE_OFF.match(l))
    on = sum(1 for l in text.split("\n") if INSERT_ON.match(l) or REPLACE_ON.match(l))
    return off, on


def validate_skills(bundle):
    """Apple's rules for a skills bundle, plus the 10,000-character body limit."""
    problems, names = [], []
    skills_dir = os.path.join(bundle, "Skills")
    if not os.path.isdir(skills_dir):
        return [f"{bundle}: no Skills folder"], names
    for entry in sorted(os.listdir(skills_dir)):
        path = os.path.join(skills_dir, entry)
        if entry.startswith("."):
            continue
        if not os.path.isdir(path):
            problems.append(f"{entry}: only skill folders belong in Skills/")
            continue
        if not re.fullmatch(r"[a-z0-9-]+", entry):
            problems.append(f"{entry}: folder names use lowercase letters, numbers and hyphens only")
        files = [f for f in os.listdir(path) if not f.startswith(".")]
        if files != ["SKILL.md"]:
            problems.append(f"{entry}: must contain only SKILL.md (has {files})")
            continue
        text = open(os.path.join(path, "SKILL.md"), encoding="utf-8").read()
        m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
        if not m:
            problems.append(f"{entry}: missing --- frontmatter")
            continue
        fields = {}
        for line in m.group(1).split("\n"):
            if ":" not in line:
                problems.append(f"{entry}: bad frontmatter line {line!r}")
                continue
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
        if set(fields) != {"name", "description"}:
            problems.append(f"{entry}: frontmatter must have exactly name and description (has {sorted(fields)})")
        if fields.get("name") != entry:
            problems.append(f"{entry}: name {fields.get('name')!r} doesn't match the folder")
        if not fields.get("description"):
            problems.append(f"{entry}: empty description")
        body = m.group(2).strip()
        if len(body) > SKILL_BODY_LIMIT:
            problems.append(f"{entry}: body is {len(body)} characters (limit {SKILL_BODY_LIMIT})")
        if re.search(r"\b[A-Z][A-Za-z]+Intent\b", body):
            problems.append(f"{entry}: refer to tools informally, not by type name")
        names.append(fields.get("name", entry))
    if len(set(names)) != len(names):
        problems.append("skill names must be unique")
    return problems, names


def sdk_probe():
    """True when this SDK has the Siri AI APIs (typechecks a tiny probe)."""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "probe.swift")
        with open(path, "w") as f:
            f.write(PROBE)
        version = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], capture_output=True, text=True).stdout.strip()
        result = subprocess.run(
            ["xcrun", "--sdk", "macosx", "swiftc", "-typecheck", "-target", f"arm64-apple-macos{version}", path],
            capture_output=True, text=True,
        )
        return result.returncode == 0, version, result.stderr.strip().splitlines()[:3]


def parses(paths_texts):
    """Syntax-checks the enabled form of each file (no type checking)."""
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, (path, text) in enumerate(paths_texts):
            out = os.path.join(tmp, f"{i}.swift")
            with open(out, "w") as f:
                f.write(text)
            result = subprocess.run(["xcrun", "swiftc", "-parse", out], capture_output=True, text=True)
            if result.returncode != 0:
                failures.append((path, result.stderr.strip().splitlines()[:3]))
    return failures


def is_enabled():
    return os.path.isdir(STAGED_SWIFT_DEST)


def cmd_status():
    print(f"Siri AI pieces: {'ON' if is_enabled() else 'off'}")
    total_off = total_on = 0
    for path in swift_files():
        off, on = counts(open(path, encoding="utf-8").read())
        if off or on:
            print(f"  {os.path.relpath(path, ROOT)}: {off} staged, {on} on")
        total_off += off
        total_on += on
    print(f"  total: {total_off} staged, {total_on} on")
    print(f"  iOS skills bundle installed: {os.path.isdir(IOS_SKILLS_DEST)}")


def cmd_check():
    ok = True
    problems, names = validate_skills(os.path.join(STAGED, "Skills.skillsbundle"))
    print(f"Skills: {', '.join(names)}")
    for problem in problems:
        ok = False
        print(f"  problem: {problem}")
    missing = [s for s in IOS_SKILLS if s not in names]
    if missing:
        ok = False
        print(f"  problem: iOS skills not in the bundle: {missing}")

    enabled = []
    for path in swift_files():
        text = open(path, encoding="utf-8").read()
        new, changed = transform(text, enable=True)
        if changed:
            enabled.append((os.path.relpath(path, ROOT), new))
        # Round trip: enable then disable must give the file back.
        back, _ = transform(new, enable=False)
        if back != text and not is_enabled():
            ok = False
            print(f"  problem: {os.path.relpath(path, ROOT)} doesn't round-trip")
    for staged in sorted(os.listdir(os.path.join(STAGED, "LidIAAppIntents"))):
        if staged.endswith(".swift"):
            enabled.append((f"Siri/Staged-27.3/LidIAAppIntents/{staged}", open(os.path.join(STAGED, "LidIAAppIntents", staged), encoding="utf-8").read()))
    failures = parses(enabled)
    print(f"Enabled code: {len(enabled)} files {'parse' if not failures else 'FAIL to parse'}")
    for path, lines in failures:
        ok = False
        print(f"  {path}: {' / '.join(lines)}")

    available, version, errors = sdk_probe()
    print(f"SDK {version}: Siri AI APIs {'available' if available else 'NOT available'}")
    if not available:
        print("  (expected before Xcode 27.3) " + " / ".join(errors))
    return 0 if ok else 1


def cmd_enable(force):
    if is_enabled():
        print("Already on.")
        return 0
    available, version, errors = sdk_probe()
    if not available and not force:
        print(f"SDK {version} doesn't have the Siri AI APIs; install Xcode 27.3 and select it (xcode-select), or pass --force.")
        print("  " + " / ".join(errors))
        return 1
    changed_files = 0
    for path in swift_files():
        text = open(path, encoding="utf-8").read()
        new, changed = transform(text, enable=True)
        if changed:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
            changed_files += 1
    os.makedirs(STAGED_SWIFT_DEST)
    for name in os.listdir(os.path.join(STAGED, "LidIAAppIntents")):
        if name.endswith(".swift"):
            shutil.copy2(os.path.join(STAGED, "LidIAAppIntents", name), STAGED_SWIFT_DEST)
    os.makedirs(os.path.join(IOS_SKILLS_DEST, "Skills"))
    for skill in IOS_SKILLS:
        shutil.copytree(os.path.join(STAGED, "Skills.skillsbundle", "Skills", skill), os.path.join(IOS_SKILLS_DEST, "Skills", skill))
    print(f"On: {changed_files} files changed, staged Swift copied, iOS skills bundle installed.")
    print("Next: build both apps (docs/siri.md, 'Switching on'), then add the Mac skills step.")
    return 0


def cmd_disable():
    changed_files = 0
    for path in swift_files():
        if os.path.dirname(path) == STAGED_SWIFT_DEST:
            continue
        text = open(path, encoding="utf-8").read()
        new, changed = transform(text, enable=False)
        if changed:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
            changed_files += 1
    if os.path.isdir(STAGED_SWIFT_DEST):
        shutil.rmtree(STAGED_SWIFT_DEST)
    if os.path.isdir(IOS_SKILLS_DEST):
        shutil.rmtree(IOS_SKILLS_DEST)
    print(f"Off: {changed_files} files restored, staged Swift and iOS skills bundle removed.")
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] not in {"status", "check", "on", "off"}:
        print(__doc__)
        return 2
    command = argv[1]
    if command == "status":
        cmd_status()
        return 0
    if command == "check":
        return cmd_check()
    if command == "on":
        return cmd_enable(force="--force" in argv)
    return cmd_disable()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
