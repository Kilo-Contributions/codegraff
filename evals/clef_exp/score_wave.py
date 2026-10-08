#!/usr/bin/env python3
"""Score clef-exp runs: recall + compaction counts + wall + cost from traces.

Recall: answer.md graded against questions.json (Q-numbered lines first;
value-set fallback for models that write the right values in the wrong
format — format compliance reported separately in `fmt`).

Cost: summed from the session trace `usage` events (server-billed input split
into ordinary/cache_read/cache_write + output), priced per model row at the
gateway tariff. The usage events carry provider+model, so each line is priced
at its own row — clef-flash decision calls ($0.09/1M in, $0 out) separate
from deepseek turns.
"""
import json, os, re, sys, glob

B = os.environ.get("CLEF_EXP_DIR", "/tmp/clef_exp")
qs = json.load(open(f"{B}/questions.json"))

# (per-1M USD): (ordinary_in, cache_read_in, cache_write_in, out)
TARIFF = {
    "deepseek-v4-flash": (0.15, 0.006, 0.15, 0.6),
    "deepseek-flash": (0.15, 0.006, 0.15, 0.6),
    "glm-5.3-flash": (0.15, 0.006, 0.15, 0.5),
    "kimi-k2.6": (0.95, 0.006, 0.95, 4.0),
    "minimax-m3": (0.3, 0.006, 0.3, 1.2),
    "clef-flash": (0.09, 0.0, 0.09, 0.0),
}
DEFAULT_TARIFF = (0.15, 0.006, 0.15, 0.6)

def price(model, ordinary, read, write, out):
    t = TARIFF.get(model, DEFAULT_TARIFF)
    toks = (ordinary + read + write + out) / 1e6
    usd = (ordinary * t[0] + read * t[1] + write * t[2] + out * t[3]) / 1e6
    return toks, usd

def archive_reads(d):
    """Tool calls whose arguments name an archived output (GRAFF_CLEF_ARCHIVE
    stubs cite .graff/sessions/<s>/artifacts/tool-N.txt): did the model go
    back for what compaction set aside?"""
    n = 0
    def walk(v):
        nonlocal n
        if isinstance(v, dict):
            a = v.get("arguments")
            if isinstance(a, str) and "artifacts/tool-" in a:
                n += 1
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    for f in glob.glob(os.path.join(d, ".graff/sessions/*.session.json")):
        try:
            walk(json.load(open(f, errors="replace")))
        except (json.JSONDecodeError, OSError):
            pass
    return n

def score_run(d):
    out = {"run": os.path.basename(d.rstrip("/"))}
    log = open(os.path.join(d, "out.log"), errors="replace").read()
    out["clef_prunes"] = log.count("[gateway compacted context")
    out["clef_noops"] = log.count("clef_compact_noop")
    out["client_compacts"] = log.count("[history compacted to") + log.count("[compacting ~")
    out["done"] = "DONE" in log
    wall = os.path.join(d, "wall_seconds")
    out["wall"] = open(wall).read().strip() + "s" if os.path.exists(wall) else "?"
    path = os.path.join(d, "answer.md")
    answers = {}
    if os.path.exists(path):
        for line in open(path, errors="replace"):
            m = re.match(r"Q(\d+):\s*(.+?)\s*$", line)
            if m:
                answers[int(m.group(1))] = m.group(2)
    # Fallback: the model wrote values without Q-numbers (bare, CONST=val,
    # or prose). Grade on value-set recall: every expected value appearing
    # anywhere in the file counts. Format compliance is reported separately.
    blob = open(path, errors="replace").read() if os.path.exists(path) else ""
    if not answers:
        # No answer.md: the model sometimes prints the 10 lines instead of
        # writing the file. Take the LAST block of Q-lines in the reply; the
        # blob stays those lines only (out.log never echoes tool output, but
        # the value-set fallback must not see anything beyond the answer).
        for line in log.splitlines():
            m = re.match(r"\s*Q(\d+):\s*(.+?)\s*$", line)
            if m and "<value>" not in m.group(2):
                if int(m.group(1)) == 1:
                    answers = {}
                answers[int(m.group(1))] = m.group(2)
        blob = "\n".join(answers.values())
        out["from_reply"] = bool(answers)
    out["format_ok"] = len(answers) == 10
    correct, wrong = 0, []
    for q in qs:
        got = answers.get(q["q"])
        exp = q["expect"]
        ok = got is not None and (got == exp or got.strip('"') == exp.strip('"'))
        if not ok and blob and exp in blob:
            ok = True  # right value, wrong line format
        if ok:
            correct += 1
        else:
            wrong.append(f'Q{q["q"]}({q["file"]}): got {got!r} want {exp!r}')
    out["score"] = f"{correct}/10"
    out["wrong"] = wrong
    # cost from usage trace events (server-billed, per model row)
    toks = usd = 0.0
    reqs = 0
    peak_in = 0
    freed = 0
    for tr in glob.glob(os.path.join(d, ".graff/traces/*.jsonl")):
        for line in open(tr, errors="replace"):
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("ev") == "clef_compact_applied":
                m = re.search(r"bytes_freed=(\d+)", ev.get("detail", ""))
                freed += int(m.group(1)) if m else 0
            if ev.get("ev") == "usage":
                model = ev.get("model", "") or ""
                reqs += 1
                if not ev.get("from_sub"):
                    peak_in = max(peak_in, ev.get("input_tokens", 0) or 0)
                # usage input_tokens already includes cache read+write; split
                # back out: ordinary = input - read - write
                ordinary = max(0, (ev.get("input_tokens", 0) or 0)
                               - (ev.get("cache_read_tokens", 0) or 0)
                               - (ev.get("cache_write_tokens", 0) or 0))
                t, u = price(model, ordinary,
                             ev.get("cache_read_tokens", 0) or 0,
                             ev.get("cache_write_tokens", 0) or 0,
                             ev.get("output_tokens", 0) or 0)
                toks += t
                usd += u
    out["api_calls"] = reqs
    out["peak_in"] = f"{peak_in // 1000}K"
    out["freed"] = f"{freed // 1000}K"
    out["arc_reads"] = archive_reads(d)
    out["mtok"] = round(toks, 3)
    out["usd"] = round(usd, 4)
    return out

runs = sorted(glob.glob(f"{B}/runs/*/"), key=os.path.getmtime)
if len(sys.argv) > 1:
    runs = [d for d in runs if any(a in d for a in sys.argv[1:])]
print(f"{'run':<10} {'score':<6} {'fmt':<4} {'clefPr':<6} {'noop':<4} {'cliCmp':<6} {'done':<5} {'wall':<6} {'api':<4} {'mtok':<6} {'usd':<7} {'peak':<5} {'freed':<6} {'arcRd':<5}")
for d in runs:
    r = score_run(d)
    print(f"{r['run']:<10} {r['score']:<6} {str(r['format_ok']):<4} {r['clef_prunes']:<6} {r['clef_noops']:<4} {r['client_compacts']:<6} "
          f"{str(r['done']):<5} {r['wall']:<6} {r['api_calls']:<4} {r['mtok']:<6} {r['usd']:<7} {r['peak_in']:<5} {r['freed']:<6} {r['arc_reads']:<5}")
    for w in r["wrong"]:
        print("   ", w)
