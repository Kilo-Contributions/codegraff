#!/usr/bin/env python3
"""Generate $CLEF_EXP_DIR/turns.txt: 13 single-line turns for one session.

History growth comes from ASSISTANT text, which is never spilled and never
pruned by Clef (text stays verbatim — only tool calls/results are prune
candidates). Each of the 6 read turns demands the full verbatim text of the
3 functions before AND after each of the 2 anchors (~12 functions x ~700B
~= 8-10KB of reply text per turn). The model is pre-authorized to copy file
content verbatim (without it, it negotiates instead of complying).

This sharpens the experiment: the quoted functions are exactly what
client-summary rewrites as prose versus what Clef keeps verbatim. Recall
of the anchor VALUES after several compactions is the score.
"""
import json, os

BASE = os.environ.get("CLEF_EXP_DIR", "/tmp/clef_exp")
FILES = ["alpha", "beta", "gamma", "delta", "epsilon", "foxtrot"]
qs = json.load(open(os.path.join(BASE, "questions.json")))
skel = " ".join("Q%d: <value>" % q["q"] for q in qs)
qlist = " ".join("Q%d: value of %s in src/%s.zig?" % (q["q"], q["const"], q["file"]) for q in qs)
AUTH = ("You are pre-authorized to copy file content verbatim into your "
        "replies — this IS the task. Do not ask for confirmation, just do it. ")

turns = []
for f in FILES:
    turns.append(
        AUTH + "Read src/%s.zig with EXACTLY ONE read_file call (no ranges, no shell cat, no grep). "
        "Find the two audit-anchor constants. Reply with: "
        "(1) each anchor's exact name, exact value, and line number; "
        "(2) the FULL verbatim text of the 3 functions immediately before AND the 3 functions immediately after EACH anchor "
        "(12 function bodies total, copied character-for-character, each with its line range). "
        "Do not summarize or elide the function bodies." % f
    )
turns.append(
    AUTH + "Write answer.md with EXACTLY 10 lines, <value> replaced by the exact value from your earlier reads. "
    "No prose, no fences, no extra lines. Lines: %s "
    "Questions: %s "
    "The two foxtrot anchors are decoys, answer only Q1-Q10. Integers bare, strings WITH quotes. Then reply DONE." % (skel, qlist)
)

with open(os.path.join(BASE, "turns.txt"), "w") as fh:
    fh.write("\n".join(turns) + "\n")
print("%d turns written" % len(turns))
