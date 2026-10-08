#!/usr/bin/env python3
"""Generate the clef-exp corpus into $CLEF_EXP_DIR/src (default /tmp/clef_exp).

Scaled-up clone of evals/compact_ab/gen_compact_bench.py: the deepseek-v4-flash
window is 1M and the forced threshold is GRAFF_COMPACT_PCT=1 -> 10k tokens.
Six files x ~80KB each; with the 1MB handle threshold every read lands inline,
and the send-time 40KB per-output spill plus assistant verbatim quotes (see
gen_turns.py) accumulate history deterministically past the threshold.

Otherwise identical shape to compact_ab: planted audit-anchor constants
mid-file (12 total, 10 asked), questions spanning all six files so
post-compaction recall of EARLY files is what separates the arms.
"""
import json, os, random

BASE = os.environ.get("CLEF_EXP_DIR", "/tmp/clef_exp")
SRC = os.path.join(BASE, "src")
rng = random.Random(20261006)

FILES = ["alpha", "beta", "gamma", "delta", "epsilon", "foxtrot"]
WORDS = ("meridian harlow pistil cinder vortex lattice ember quorum "
         "solace thresh welkin bramble copse falcon garnet hollow "
         "indigo jasper kindle lantern marrow numen obsidian palisade "
         "tundra umbra vale wistful xenon yarrow zephyr acorn birch "
         "cedar drift elm fern grove heath iris juniper kelp larch").split()

def filler_fn(name, i):
    acc = rng.randint(2, 9)
    lines = [f"fn {name}_{i:03d}(ledger: *Ledger, entry: Entry) !u64 {{"]
    lines.append(f"    var acc: u64 = entry.checksum ^ {rng.randint(100, 999)};")
    for j in range(rng.randint(3, 6)):
        op = rng.choice(["+", "-", "^", "*"])
        lines.append(f"    acc = acc {op} (@as(u64, {rng.randint(3, 977)}) +% ledger.salt[{j} % 8]);")
        lines.append(f"    if (acc % {rng.randint(3, 17)} == 0) acc +%= {rng.randint(11, 555)};")
    lines.append(f"    return acc *% {acc};")
    lines.append("}")
    return "\n".join(lines)

facts = {}   # const name -> value (string form)
used = set()

def plant(lines, fname):
    word = rng.choice([w for w in WORDS if w not in used])
    used.add(word)
    cname = f"{word.upper()}_{fname.upper()[:6]}"
    if rng.random() < 0.5:
        val = str(rng.randint(10_000, 99_999))
        decl = f'pub const {cname}: u64 = {val}; // audit anchor'
    else:
        val = f"{word}-{rng.randint(100, 999)}"
        decl = f'pub const {cname} = "{val}"; // audit anchor'
    pos = rng.randint(len(lines) // 4, 3 * len(lines) // 4)
    lines.insert(pos, decl)
    facts[cname] = val

os.makedirs(SRC, exist_ok=True)
for fidx, fname in enumerate(FILES):
    lines = [
        f"//! {fname}.zig — archival ledger segment {fidx} of the benchmark codebase.",
        "",
        "const std = @import(\"std\");",
        "const Ledger = @import(\"ledger.zig\").Ledger;",
        "const Entry = @import(\"ledger.zig\").Entry;",
        "",
    ]
    for i in range(150):  # ~1600+ lines of filler per file (~85KB each)
        lines.append(filler_fn(fname, i))
        lines.append("")
    plant(lines, fname)
    plant(lines, fname)  # two facts per file, 12 total
    with open(os.path.join(SRC, f"{fname}.zig"), "w") as f:
        f.write("\n".join(lines) + "\n")

with open(os.path.join(SRC, "ledger.zig"), "w") as f:
    f.write("//! shared types\n\npub const Ledger = struct { salt: [8]u64 };\n"
            "pub const Entry = struct { checksum: u64, route: u32 };\n")

with open(os.path.join(BASE, "facts.json"), "w") as f:
    json.dump(facts, f, indent=2)

items = list(facts.items())
questions = []
for qi, fi in enumerate(range(10), 1):
    cname, _ = items[fi]
    ffile = next(fname for fname in FILES if fname.upper()[:6] == cname.split("_")[-1])
    questions.append((qi, cname, ffile))

with open(os.path.join(BASE, "questions.json"), "w") as f:
    json.dump([{"q": q, "const": c, "file": fn, "expect": facts[c]} for q, c, fn in questions], f, indent=2)

total = sum(os.path.getsize(os.path.join(SRC, fn)) for fn in os.listdir(SRC))
print(f"generated {len(os.listdir(SRC))} files, {total/1024:.0f} KB total, {len(facts)} facts, 10 questions")
