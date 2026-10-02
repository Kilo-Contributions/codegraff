#!/usr/bin/env python3
"""Split sub-agent runs into parent and child time.

usage: subagent_split.py <output-root> [<codex-trace-dir>]

<output-root> is a run.py --output-root (results.jsonl + sandboxes/). Codex
runs need the driver's EVAL_TRACE_DIR; it defaults to <output-root>-codex-traces.

Columns, in seconds from the start of the run:
  first_spawn   the parent started its first child
  spawn_spread  first to last spawn (one spawn per model call costs this)
  child_crit    first child start to last child finish
  slowest       the longest single child
  par           child time summed over child_crit (1.0 = no overlap)
  parent_model  the parent's own model time (graff traces only)
  parent_wait   the parent blocked on agent_output (graff traces only)
  tail          last child finish to the end of the run: integration and checks

A graff child is read from its `subagent` trace line (ms and finish time);
older traces fall back to the child's model calls.
"""
import collections
import glob
import json
import os
import re
import sys

COLS = ["wall", "ok", "root_calls", "children", "child_calls", "first_spawn", "spawn_spread",
        "child_crit", "slowest", "par", "parent_model", "parent_wait", "tail"]


def graff_run(sandbox):
    traces = sorted(glob.glob(os.path.join(sandbox, ".graff", "traces", "*.jsonl")))
    if not traces:
        return None
    ev = [json.loads(line) for line in open(traces[-1]) if line.strip()]
    root_api = [(e["t"] - e.get("ms", 0), e["t"]) for e in ev if e.get("ev") == "api" and e.get("agent") == "repl"]
    spawns = [e["t"] for e in ev if e.get("ev") == "tool" and e.get("name") == "subagent" and not e.get("from_sub")]
    waits = [e.get("ms", 0) for e in ev if e.get("ev") == "tool" and e.get("name") == "agent_output" and not e.get("from_sub")]
    calls = collections.Counter(e.get("agent") for e in ev if e.get("ev") == "api" and e.get("agent") not in (None, "repl"))
    spans = {}
    for e in ev:
        if e.get("ev") == "subagent":
            m = re.search(r"label=(.*?) ms=(\d+)", e.get("detail", ""))
            if m:
                spans[m.group(1)] = (e["t"] - int(m.group(2)), e["t"], calls.get(m.group(1), 0))
    if not spans:
        kids = collections.defaultdict(list)
        for e in ev:
            if e.get("ev") == "api" and e.get("agent") not in (None, "repl", "?"):
                kids[e["agent"]].append((e["t"] - e.get("ms", 0), e["t"]))
        spans = {k: (min(a for a, _ in v), max(b for _, b in v), len(v)) for k, v in kids.items()}
    end = max([b for _, b in root_api] + [s[1] for s in spans.values()] + [0])
    return summary(end, len(root_api), sum(b - a for a, b in root_api), sum(waits), spawns, spans)


def codex_run(path):
    ev = [json.loads(line) for line in open(path) if line.strip()]
    root_calls = sum(1 for e in ev if e.get("ev") == "usage" and e.get("thread") == "root")
    spawns = [e["t"] for e in ev if e.get("type") == "subAgentActivity" and e.get("thread") == "root"]
    kids = collections.defaultdict(list)
    for e in ev:
        if e.get("thread") == "child":
            kids[e.get("tid") or "child"].append(e)
    spans = {}
    for tid, items in kids.items():
        first = min(e["t"] for e in items)
        start = max([s for s in spawns if s <= first] or [first])
        spans[tid] = (start, max(e["t"] for e in items), sum(1 for e in items if e.get("ev") == "usage"))
    end = max([e["t"] for e in ev] + [0])
    return summary(end, root_calls, None, None, spawns, spans)


def summary(end, root_calls, parent_model, parent_wait, spawns, spans):
    out = {"root_calls": root_calls, "children": len(spans)}
    if parent_model is not None:
        out["parent_model"] = parent_model / 1000
        out["parent_wait"] = parent_wait / 1000
    if spawns:
        out["first_spawn"] = min(spawns) / 1000
        out["spawn_spread"] = (max(spawns) - min(spawns)) / 1000
    if spans:
        lo = min(s[0] for s in spans.values())
        hi = max(s[1] for s in spans.values())
        crit = (hi - lo) / 1000
        out.update(child_crit=crit, slowest=max(s[1] - s[0] for s in spans.values()) / 1000,
                   child_calls=sum(s[2] for s in spans.values()), tail=(end - hi) / 1000,
                   par=(sum(s[1] - s[0] for s in spans.values()) / 1000 / crit) if crit > 0 else 0.0)
    return out


def main():
    root = sys.argv[1]
    codex_dir = sys.argv[2] if len(sys.argv) > 2 else root.rstrip("/") + "-codex-traces"
    rows = [json.loads(line) for line in open(os.path.join(root, "results.jsonl"))]
    print(f"{'task':16} {'harness':17} " + " ".join(f"{c:>12}" for c in COLS))
    for r in sorted(rows, key=lambda r: (r["task"], r["harness"], r.get("rep", 0))):
        name = f"{r['harness']}-{r['task']}-r{r.get('rep', 1)}"
        if r["harness"].startswith("codex"):
            path = os.path.join(codex_dir, name + ".jsonl")
            d = codex_run(path) if os.path.exists(path) else None
        else:
            d = graff_run(os.path.join(root, "sandboxes", name))
        d = dict(d or {}, wall=r.get("wall_s"), ok=r.get("outcome_ok"))
        cells = [f"{d[c]:>12.1f}" if isinstance(d.get(c), float) else f"{str(d.get(c, '-')):>12}" for c in COLS]
        print(f"{r['task']:16} {r['harness']:17} " + " ".join(cells))


if __name__ == "__main__":
    main()
