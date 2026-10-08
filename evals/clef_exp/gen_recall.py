#!/usr/bin/env python3
"""Recall variant: facts live ONLY in tool output, and the source is gone.

The main task (gen_corpus.py + gen_turns.py) ties at 10/10 on every arm
because each turn restates the anchor values in assistant text, which
nothing prunes. Here each read turn is `cat src/logs/run-NN.log && rm ...` with a
reply of exactly "OK": the facts exist only in that one tool result, and
re-running the tool cannot recover them. After the reads, filler turns
push history over the threshold again, then the last turn asks about facts
from every log (early logs are the ones compaction should have touched).

What can still answer: the live tool result (none, or a kept output), the
summary text (client / clef fallback), the #391 pre-compaction note, or an
archived artifact (clefarc). Delete-mode drops have nothing to fall back on.

Each log stays well under the 40KB per-output cap so the send-time #409
spill never fires — otherwise every arm would get an artifact path for free.

Writes $CLEF_EXP_DIR (default /tmp/clef_recall): src/logs/*.log,
questions.json, facts.json, turns.txt. Run with
`CLEF_EXP_DIR=/tmp/clef_recall bash evals/clef_exp/run_wave.sh recall N`.
"""
import json, os, random

BASE = os.environ.get("CLEF_EXP_DIR", "/tmp/clef_recall")
LOGS = os.path.join(BASE, "src", "logs")
rng = random.Random(20261007)
N_LOGS = 8
LINES = 170  # ~20KB per log, under the 40KB per-output cap

SVCS = ["ledger", "billing", "auth", "router", "search", "notify", "export", "queue"]
LEVELS = ["INFO"] * 8 + ["DEBUG"] * 3 + ["WARN"]
OWNERS = ("harlow pistil cinder vortex lattice ember quorum solace welkin "
          "bramble falcon garnet jasper kindle marrow obsidian").split()

def rid():
    return "".join(rng.choice("abcdef0123456789") for _ in range(12))

def noise(ts, svc):
    lvl = rng.choice(LEVELS)
    return (f"2026-10-06T{ts // 3600:02d}:{ts // 60 % 60:02d}:{ts % 60:02d}Z {lvl:<5} "
            f"svc={svc} req={rid()} route=/v{rng.randint(1, 3)}/{rng.choice(SVCS)} "
            f"status={rng.choice([200, 200, 200, 201, 204, 304, 404, 429, 500])} "
            f"latency={rng.randint(2, 900)}ms bytes={rng.randint(80, 90000)} "
            f"shard={rng.randint(0, 63)} retry={rng.randint(0, 3)}")

# Two kinds of planted fact per log: an incident id + owner (one line) and a
# rollback token (another line). Values are unguessable and appear once.
facts, questions = {}, []
os.makedirs(LOGS, exist_ok=True)
for i in range(1, N_LOGS + 1):
    name = f"run-{i:02d}.log"
    svc = SVCS[i - 1]
    ts = 3600 * (i + 1)
    lines = []
    for _ in range(LINES):
        ts += rng.randint(1, 9)
        lines.append(noise(ts, svc))
    inc = f"INC-{rng.randint(10000, 99999)}"
    owner = rng.choice(OWNERS)
    tok = f"rbk-{rng.choice('kqzxvw')}{rng.randint(100, 999)}-{rng.randint(1000, 9999)}"
    a, b = sorted(rng.sample(range(LINES // 5, 4 * LINES // 5), 2))
    lines[a] = lines[a].split(" svc=")[0].replace("INFO ", "WARN ").replace("DEBUG", "WARN ") + \
        f" svc={svc} incident opened id={inc} owner={owner} cause=shard-skew"
    lines[b] = lines[b].split(" svc=")[0] + f" svc={svc} rollback token issued token={tok} scope=shard-{rng.randint(0, 63)}"
    with open(os.path.join(LOGS, name), "w") as f:
        f.write("\n".join(lines) + "\n")
    facts[f"{name}:incident"] = inc
    facts[f"{name}:token"] = tok

# 10 questions: incident ids from logs 1-5 (early: compacted away) and
# rollback tokens from logs 1-3 and 7-8 (7-8 are recent: a control).
plan = [(i, "incident") for i in (1, 2, 3, 4, 5)] + [(i, "token") for i in (1, 2, 3, 7, 8)]
for q, (i, kind) in enumerate(plan, 1):
    name = f"run-{i:02d}.log"
    what = "incident id opened" if kind == "incident" else "rollback token issued"
    questions.append({"q": q, "const": what, "file": name, "expect": facts[f"{name}:{kind}"]})

with open(os.path.join(BASE, "facts.json"), "w") as f:
    json.dump(facts, f, indent=2)
with open(os.path.join(BASE, "questions.json"), "w") as f:
    json.dump(questions, f, indent=2)

turns = []
for i in range(1, N_LOGS + 1):
    name = f"src/logs/run-{i:02d}.log"
    turns.append(
        f"Shift handover, log {i} of {N_LOGS}. Run exactly this one shell command and nothing else: "
        f"cat {name} && rm {name} . The log is one-shot (it is deleted after reading, that is expected). "
        "Do not summarize it, do not take notes, do not write any file. Reply with exactly: OK"
    )
for k in range(3):  # filler: grow history past the threshold after the last read
    turns.append(
        "Unrelated warm-up, no tools: write a 400-word plain-prose explanation of how "
        f"{['exponential backoff', 'consistent hashing', 'write-ahead logging'][k]} works. "
        "Do not mention the logs."
    )
skel = " ".join(f"Q{q['q']}: <value>" for q in questions)
qlist = " ".join(f"Q{q['q']}: the {q['const']} in {q['file']}?" for q in questions)
turns.append(
    "The logs are deleted and cannot be re-run. Answer from what you saw earlier in this session "
    "(you may read any file this session itself saved, but src/logs/ is gone). "
    f"Write answer.md with EXACTLY 10 lines, <value> replaced by the exact value, or UNKNOWN if you "
    f"no longer have it — do not guess. No prose, no fences. Lines: {skel} Questions: {qlist} Then reply DONE."
)
with open(os.path.join(BASE, "turns.txt"), "w") as f:
    f.write("\n".join(turns) + "\n")

sizes = [os.path.getsize(os.path.join(LOGS, n)) for n in sorted(os.listdir(LOGS))]
print(f"{N_LOGS} logs, {min(sizes)//1024}-{max(sizes)//1024}KB each, {len(questions)} questions, {len(turns)} turns -> {BASE}")
