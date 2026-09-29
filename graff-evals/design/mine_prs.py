#!/usr/bin/env python3
"""Mine live eval tasks from merged pull requests (ADR 0214).

A merged PR that adds named Zig tests and changes non-test code is a task the
project already judged worth doing. The merge's first parent is the starting
tree (recent parents build on the pinned toolchain, so no reconstruction), the
PR's first new test is the public check the prompt names, and a second new
test is the hidden check appended only at grading time.

Before anything is offered for review, each grader is validated:

  red     on the parent tree plus both tests, neither passes (a compile
          error or a test the module graph never reaches counts)
  green   on the merge tree, both tests pass
  stable  a second run on the merge tree gives the same verdicts

    ./design/mine_prs.py list [--days 21] [--limit 40]
    ./design/mine_prs.py build <pr> [--public NAME] [--hidden NAME]
    ./design/mine_prs.py validate <task-id>        # three full test runs
    ./design/mine_prs.py review                    # writes design/local/review.md
    ./design/mine_prs.py approve <task-id>         # candidate -> mined suite

Grading builds only the filtered unit-test binary and requires each named
test to have run (named_unit_check.py). Validation grades three times per
task: one build at a time, never in parallel with another build.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
EVALS = os.path.dirname(HERE)
REPO = os.path.dirname(EVALS)
sys.path.insert(0, EVALS)
import live_setup  # noqa: E402
import named_unit_check  # noqa: E402

MINED = os.path.join(EVALS, "live", "mined.json")  # catalog.json stays hand-edited
TASKS = os.path.join(EVALS, "tasks")
LOCAL = os.path.join(HERE, "local")
MERGE_RE = re.compile(r"^Merge pull request #(\d+) from ")
TEST_RE = re.compile(r'^\+\s*test "((?:[^"\\]|\\.)*)"\s*\{')
SKIP_TITLES = ("release", "merge release", "merge current release", "docs:", "readme", "adr ", "changelog")
MAX_CHANGED = 900  # lines; larger PRs are not a fair single task


def git(*args: str, check: bool = True) -> str:
    p = subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True)
    if check and p.returncode != 0:
        raise SystemExit(f"git {' '.join(args)}: {p.stderr.strip()}")
    return p.stdout


def merged_prs(days: int, ref: str) -> list[dict]:
    out = git("log", ref, "--first-parent", "--merges", f"--since={days}.days", "--format=%H%x09%s")
    rows = []
    for line in out.splitlines():
        sha, _, subject = line.partition("\t")
        m = MERGE_RE.match(subject)
        if not m:
            continue
        body = git("show", "-s", "--format=%b", sha).strip().splitlines()
        rows.append({"pr": int(m.group(1)), "merge": sha, "parent": f"{sha}^1",
                     "title": (body[0] if body else subject).strip()})
    return rows


def is_test_file(path: str) -> bool:
    base = os.path.basename(path)
    return base.endswith(("_tests.zig", "_test.zig")) or "/tests/" in path


def added_tests(parent: str, merge: str) -> list[dict]:
    diff = git("diff", "-U0", parent, merge, "--", "src", "TUI")
    tests, current = [], None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current = line[6:]
        elif current and current.endswith(".zig"):
            m = TEST_RE.match(line)
            if m:
                tests.append({"file": current, "name": m.group(1)})
    return tests


def changed_lines(parent: str, merge: str) -> tuple[int, int]:
    """(all changed lines, changed lines in non-test source)."""
    total = source = 0
    for line in git("diff", "--numstat", parent, merge).splitlines():
        parts = line.split("\t")
        if len(parts) != 3 or not parts[0].isdigit():
            continue
        n = int(parts[0]) + int(parts[1])
        total += n
        if parts[2].endswith(".zig") and parts[2].startswith(("src/", "TUI/")) and not is_test_file(parts[2]):
            source += n
    return total, source


def candidates(days: int, ref: str, limit: int) -> list[dict]:
    out = []
    for pr in merged_prs(days, ref):
        if pr["title"].lower().startswith(SKIP_TITLES):
            continue
        tests = added_tests(pr["parent"], pr["merge"])
        total, source = changed_lines(pr["parent"], pr["merge"])
        pr.update(tests=tests, changed=total, source_changed=source)
        pr["fit"] = ("ok" if tests and source and total <= MAX_CHANGED else
                     "no new named test" if not tests else
                     "tests only" if not source else "too large")
        out.append(pr)
        if len(out) >= limit:
            break
    return out


# ── Zig test blocks ──────────────────────────────────────────────────────

def test_block(text: str, name: str) -> str | None:
    """The full `test "name" { … }` block, braces matched outside strings,
    char literals, `//` comments and `\\\\` multiline string lines."""
    head = f'test "{name}"'
    start = text.find(head)
    if start < 0:
        return None
    # Include the doc comments / blank line directly above? No: the block only.
    i = text.find("{", start + len(head))
    if i < 0:
        return None
    depth, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "\\" and text.startswith("\\\\", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c in "\"'":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            i = j + 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1] + "\n"
        i += 1
    return None


def file_at(rev: str, path: str) -> str:
    return git("show", f"{rev}:{path}")


# ── task files ───────────────────────────────────────────────────────────

def load_catalog() -> dict:
    if not os.path.exists(MINED):
        return {"note": "Machine-managed by design/mine_prs.py (ADR 0214). catalog.json stays hand-edited.",
                "candidates": [], "mined": []}
    with open(MINED) as f:
        return json.load(f)


def save_catalog(cat: dict) -> None:
    with open(MINED, "w") as f:
        json.dump(cat, f, indent=1, ensure_ascii=False)
        f.write("\n")


def write(path: str, text: str, mode: int = 0o644) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


def prompt_for(title: str, public: dict) -> str:
    # State what the grader checks: the test must run in the project's own
    # test build. "Make it pass" alone let a run prove it in a temporary
    # harness and leave it unreachable from the suite (ADR 0214).
    return (f"{title}. Make the test named \"{public['name']}\" in {public['file']} run and pass "
            "in the project's unit tests (`zig build test`), not only in isolation. "
            "Do not edit that test. Do not add SPEC.md.")


def build(pr_number: int, public_name: str | None, hidden_name: str | None, ref: str) -> str:
    found = [p for p in merged_prs(3650, ref) if p["pr"] == pr_number]
    if not found:
        raise SystemExit(f"#{pr_number} is not a merged PR on {ref}")
    pr = found[0]
    tests = added_tests(pr["parent"], pr["merge"])
    if not tests:
        raise SystemExit(f"#{pr_number} adds no named Zig test")
    pick = lambda name, default: next((t for t in tests if t["name"] == name), None) if name else default
    public = pick(public_name, tests[0])
    hidden = pick(hidden_name, next((t for t in tests if t is not public and t["name"] != public["name"]), None))
    if public is None:
        raise SystemExit(f"no added test named {public_name!r}")
    task_id = f"pr-{pr_number}"
    blocks = {}
    for role, t in (("public", public), ("hidden", hidden)):
        if t is None:
            continue
        block = test_block(file_at(pr["merge"], t["file"]), t["name"])
        if block is None:
            raise SystemExit(f"could not extract test {t['name']!r} from {t['file']}")
        blocks[role] = block
    tdir = os.path.join(EVALS, "live", task_id)
    public_text = "\n" + blocks["public"]
    parent_has = subprocess.run(["git", "-C", REPO, "cat-file", "-e", f"{pr['parent']}:{public['file']}"],
                                capture_output=True).returncode == 0
    if not parent_has and is_test_file(public["file"]):
        # A new test-only file is part of the spec: without its imports and
        # helpers the test cannot compile unless the test file is edited,
        # which the prompt forbids. Ship the whole file, minus the hidden
        # test. (A new source module with inline tests is the solution
        # itself, so there only the test block is given.)
        public_text = file_at(pr["merge"], public["file"])
        if hidden and hidden["file"] == public["file"]:
            public_text = public_text.replace(blocks["hidden"], "")
    write(os.path.join(tdir, "public_case.inc"), public_text)
    write(os.path.join(tdir, "check_public.sh"),
          "#!/bin/sh\nset -eu\nTASK_ROOT=${TASK_ROOT:?}\n"
          f"exec python3 \"$TASK_ROOT/named_unit_check.py\" {json.dumps(public['name'])}\n", 0o755)
    hidden_rel = None
    if hidden:
        write(os.path.join(tdir, "hidden_case.inc"), "\n" + blocks["hidden"])
        hidden_rel = f"hidden/{task_id}.sh"
        write(os.path.join(EVALS, hidden_rel),
              "#!/bin/sh\nset -eu\nTASK_ROOT=${TASK_ROOT:?}\n"
              f"INC=\"$TASK_ROOT/live/{task_id}/hidden_case.inc\"\n"
              f"if ! grep -qF {json.dumps('test ' + json.dumps(hidden['name']))} {hidden['file']} 2>/dev/null; then\n"
              f"  cat \"$INC\" >> {hidden['file']}\nfi\n"
              f"exec python3 \"$TASK_ROOT/named_unit_check.py\" {json.dumps(hidden['name'])}\n", 0o755)
    entry = {
        "id": task_id, "pr": f"codegraff #{pr_number}", "why": pr["title"],
        "repo": "justrach/codegraff", "historical_parent": git("rev-parse", pr["parent"]).strip(),
        "historical_merge": pr["merge"], "source": "local-git",
        "public_filter": public["name"], "public_file": public["file"],
        "hidden": hidden_rel, "hidden_filter": hidden["name"] if hidden else None,
        "hidden_file": hidden["file"] if hidden else None, "check_timeout_s": 420,
        "validation": None,
    }
    cat = load_catalog()
    cat.setdefault("candidates", [])
    cat["candidates"] = [c for c in cat["candidates"] if c["id"] != task_id] + [entry]
    save_catalog(cat)
    check = f"sh \"$TASK_ROOT/live/{task_id}/check_public.sh\""
    if hidden_rel:
        check += f" && sh \"$TASK_ROOT/{hidden_rel}\""
    task = {"id": task_id, "suite": "mined-candidate", "category": "live",
            "source": f"codegraff #{pr_number} — mined (ADR 0214)", "prompt": prompt_for(pr["title"], public),
            "setup": [f"python3 \"$TASK_ROOT/live_setup.py\" {task_id} ."], "check": check,
            "timeout_s": 900, "setup_timeout_s": 300, "check_timeout_s": 420}
    write(os.path.join(TASKS, f"mined-{task_id}.json"), json.dumps(task, indent=1, ensure_ascii=False) + "\n")
    return task_id


# ── validation (red on parent, green and stable on merge) ────────────────

def validate(task_id: str) -> dict:
    cat = load_catalog()
    entry = next((c for c in cat.get("candidates", []) if c["id"] == task_id), None)
    if entry is None:
        raise SystemExit(f"{task_id} is not a candidate; build it first")
    tdir = os.path.join(EVALS, "live", task_id)
    names = [(entry["public_file"], os.path.join(tdir, "public_case.inc"), entry["public_filter"])]
    if entry.get("hidden_filter"):
        names.append((entry["hidden_file"], os.path.join(tdir, "hidden_case.inc"), entry["hidden_filter"]))
    timeout = entry.get("check_timeout_s", 420)
    result = {"red": {}, "green": {}, "stable": {}}
    tests = [name for _, _, name in names]
    with tempfile.TemporaryDirectory(prefix=f"mine-{task_id}-") as tmp:
        parent, merge = os.path.join(tmp, "parent"), os.path.join(tmp, "merge")
        live_setup.archive_local(entry["historical_parent"], parent)
        for rel, inc, name in names:
            live_setup.append_case(parent, rel, inc, name)
        result["red"] = named_unit_check.grade(parent, tests, timeout)
        shutil.rmtree(parent)
        live_setup.archive_local(entry["historical_merge"], merge)
        result["green"] = named_unit_check.grade(merge, tests, timeout)
        result["stable"] = named_unit_check.grade(merge, tests, timeout)
    ok = (all(v != "pass" for v in result["red"].values())
          and all(v == "pass" for v in result["green"].values())
          and result["stable"] == result["green"])
    result["ok"] = ok
    entry["validation"] = result
    save_catalog(cat)
    return result


# ── review and approval ──────────────────────────────────────────────────

def review() -> str:
    cat = load_catalog()
    lines = ["# Mined task candidates", "",
             "Approve only tasks you would judge hard and representative; the loop never sees the hidden test.", ""]
    for c in cat.get("candidates", []):
        v = c.get("validation") or {}
        status = "not validated" if not v else ("valid" if v.get("ok") else f"INVALID {v}")
        lines += [f"## {c['id']} — {c['why']}", f"- source: {c['pr']} (parent {c['historical_parent'][:10]})",
                  f"- public: `{c['public_filter']}` in {c['public_file']}",
                  f"- hidden: `{c.get('hidden_filter') or '—'}`", f"- grader: {status}", ""]
    os.makedirs(LOCAL, exist_ok=True)
    path = os.path.join(LOCAL, "review.md")
    with open(path, "w") as f:
        f.write("\n".join(lines))
    return path


def approve(task_id: str) -> None:
    cat = load_catalog()
    entry = next((c for c in cat.get("candidates", []) if c["id"] == task_id), None)
    if entry is None:
        raise SystemExit(f"{task_id} is not a candidate")
    if not (entry.get("validation") or {}).get("ok"):
        raise SystemExit(f"{task_id} has no passing validation; run validate first")
    cat["candidates"] = [c for c in cat["candidates"] if c["id"] != task_id]
    cat.setdefault("mined", []).append(entry)
    save_catalog(cat)
    path = os.path.join(TASKS, f"mined-{task_id}.json")
    task = json.load(open(path))
    task["suite"] = "mined"
    write(path, json.dumps(task, indent=1, ensure_ascii=False) + "\n")


# ── self-test (no git history or builds needed) ──────────────────────────

def self_test() -> None:
    src = ('const std = @import("std");\n'
           'test "outer { brace in name" {\n'
           '    const s = "}{";\n'
           "    const c = '}';\n"
           "    // } comment brace\n"
           "    const m =\n"
           "        \\\\ multiline } brace\n"
           "    ;\n"
           "    if (true) { _ = s; _ = c; _ = m; }\n"
           "}\n"
           'test "second" {}\n')
    block = test_block(src, "outer { brace in name")
    assert block and block.startswith('test "outer') and block.rstrip().endswith("}"), block
    assert 'test "second"' not in block
    assert test_block(src, "second") == 'test "second" {}\n'
    assert test_block(src, "missing") is None
    assert TEST_RE.match('+test "a \\"quoted\\" name" {').group(1) == 'a \\"quoted\\" name'
    prompt = prompt_for("Fix it", {"name": "alpha", "file": "src/a.zig"})
    assert "run and pass in the project's unit tests (`zig build test`)" in prompt, prompt
    print("mine_prs self-test ok")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ref", default="origin/main")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list"); p.add_argument("--days", type=int, default=21); p.add_argument("--limit", type=int, default=40)
    p = sub.add_parser("build"); p.add_argument("pr", type=int); p.add_argument("--public"); p.add_argument("--hidden")
    p = sub.add_parser("validate"); p.add_argument("task_id")
    sub.add_parser("review")
    p = sub.add_parser("approve"); p.add_argument("task_id")
    sub.add_parser("self-test")
    a = ap.parse_args()
    if a.cmd == "list":
        for c in candidates(a.days, a.ref, a.limit):
            names = ", ".join(t["name"] for t in c["tests"][:3]) or "—"
            print(f"#{c['pr']:<5} {c['fit']:<18} {c['changed']:>5} lines  {c['title'][:70]}\n        tests: {names[:140]}")
    elif a.cmd == "build":
        print(build(a.pr, a.public, a.hidden, a.ref))
    elif a.cmd == "validate":
        print(json.dumps(validate(a.task_id), indent=1))
    elif a.cmd == "review":
        print(review())
    elif a.cmd == "approve":
        approve(a.task_id)
        print(f"{a.task_id} approved into the mined suite")
    else:
        self_test()


if __name__ == "__main__":
    main()
