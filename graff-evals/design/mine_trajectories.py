#!/usr/bin/env python3
"""Find what to evaluate from local trajectories (ADR 0214).

Reads the `.graff/traces/*.jsonl` files graff writes in each project and the
saved transcripts next to them, and reports where runs actually go wrong:
tool error rates by tool and model, prompt-cache reuse, cache resets at turn
starts (split by idle gap), stalls and retries, turns that stopped with work
still open, and the most common refusal texts. The point is to pick eval
cases from evidence a person can judge, not from one model's failures.

The report can contain local paths and prompts, so it is written under
design/local/ (ignored by git) and never belongs in an issue or PR.

    ./design/mine_trajectories.py [--days 14] [--root ~] [--json]
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import re
import statistics as st
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LOCAL = os.path.join(HERE, "local")


def pct(xs: list[float], p: float):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else None


def trace_files(root: str, days: int, sub: str, pattern: str) -> list[str]:
    root = os.path.expanduser(root)
    dirs = glob.glob(os.path.join(root, "*", ".graff", sub)) + [os.path.join(root, ".graff", sub)]
    cutoff = time.time() - days * 86400
    return [f for d in dirs for f in glob.glob(os.path.join(d, pattern)) if os.path.getmtime(f) > cutoff]


def load_events(files: list[str]) -> list[list[dict]]:
    runs = []
    for f in files:
        rows = []
        for line in open(f, errors="replace"):
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
        runs.append(rows)
    return runs


def tool_table(runs: list[list[dict]]) -> list[dict]:
    by = collections.defaultdict(lambda: {"n": 0, "err": 0, "ms": []})
    for rows in runs:
        for e in rows:
            if e.get("ev") == "tool":
                b = by[e.get("name")]
                b["n"] += 1
                b["err"] += bool(e.get("is_error"))
                b["ms"].append(e.get("ms") or 0)
    out = [{"tool": k, "calls": v["n"], "error_pct": round(100 * v["err"] / v["n"], 1),
            "p95_ms": pct(v["ms"], .95)} for k, v in by.items()]
    return sorted(out, key=lambda r: -r["calls"])


def tool_errors_by_model(runs: list[list[dict]], tools=("read_file", "write_file", "edit_file", "shell")) -> list[dict]:
    by = collections.defaultdict(lambda: [0, 0])
    for rows in runs:
        model = None
        for e in rows:
            if e.get("ev") == "api":
                model = e.get("model")
            if e.get("ev") == "tool" and e.get("name") in tools:
                k = (e["name"], model)
                by[k][0] += 1
                by[k][1] += bool(e.get("is_error"))
    return sorted(({"tool": t, "model": m, "calls": n, "error_pct": round(100 * err / n, 1)}
                   for (t, m), (n, err) in by.items() if n >= 30), key=lambda r: -r["error_pct"])


def cache_table(runs: list[list[dict]]) -> list[dict]:
    """Server-reported reuse from `usage` lines; the meter fallback is flagged."""
    real = collections.defaultdict(list)
    meter = collections.defaultdict(list)
    for rows in runs:
        for e in rows:
            if e.get("ev") == "usage" and not e.get("from_sub") and (e.get("input_tokens") or 0) >= 2048:
                real[e.get("model")].append(e["cache_read_tokens"] / e["input_tokens"])
            elif e.get("ev") == "api" and not e.get("is_error") and not e.get("from_sub") and (e.get("context_tokens") or 0) > 15000:
                meter[e.get("model")].append(min(1, (e.get("cache_read_tokens") or 0) / e["context_tokens"]))
    out = []
    for m in set(real) | set(meter):
        if real.get(m):
            out.append({"model": m, "requests": len(real[m]), "reuse_pct": round(100 * st.mean(real[m]), 1), "source": "usage"})
        elif len(meter[m]) >= 20:
            out.append({"model": m, "requests": len(meter[m]), "reuse_pct": round(100 * st.mean(meter[m]), 1),
                        "source": "meter (not a hit rate: see docs/architecture.md)"})
    return sorted(out, key=lambda r: -r["requests"])


def turn_resets(runs: list[list[dict]], idle_s: int = 600) -> list[dict]:
    """A turn whose first request reads under half the previous request's
    cache is a reset; resets after a long idle gap are provider expiry."""
    by = collections.defaultdict(lambda: {"boundaries": 0, "idle_resets": 0, "other_resets": 0})
    for rows in runs:
        prev = None
        for e in rows:
            if e.get("ev") != "api" or e.get("is_error") or e.get("from_sub"):
                continue
            r, turn, t = e.get("cache_read_tokens") or 0, e.get("turn"), e.get("t") or 0
            if prev and prev["model"] == e.get("model") and turn != prev["turn"] and prev["read"] > 20000:
                b = by[e.get("model")]
                b["boundaries"] += 1
                if r < 0.5 * prev["read"]:
                    b["idle_resets" if (t - prev["t"]) / 1000 > idle_s else "other_resets"] += 1
            prev = {"model": e.get("model"), "read": r, "turn": turn, "t": t}
    return sorted(({"model": m, **v} for m, v in by.items() if v["boundaries"] >= 10), key=lambda r: -r["boundaries"])


def counted_details(runs: list[list[dict]], evs=("stream_retry", "stall_budget", "retry", "fake_done",
                                                  "ws_api_error", "pending_work")) -> dict:
    out = {}
    for ev in evs:
        c = collections.Counter(str(e.get("detail"))[:90] for rows in runs for e in rows if e.get("ev") == ev)
        if c:
            out[ev] = c.most_common(5)
    return out


def refusal_texts(files: list[str], top: int = 12) -> list[tuple[int, str, str]]:
    """Most common error openings in saved transcripts, by tool."""
    counts = collections.Counter()
    for f in files:
        calls = {}
        for line in open(f, errors="replace"):
            try:
                m = json.loads(line)
            except ValueError:
                continue
            for tc in m.get("tool_calls") or []:
                calls[tc.get("id")] = (tc.get("function") or {}).get("name")
            if m.get("role") == "tool":
                c = m.get("content")
                c = c if isinstance(c, str) else json.dumps(c)
                if c.startswith("[error]"):
                    first = re.sub(r"\d+", "N", re.sub(r"'[^']*'", "'X'", c.split("\n")[0]))
                    counts[(calls.get(m.get("tool_call_id")) or "?", first[:110])] += 1
    return [(n, tool, text) for (tool, text), n in counts.most_common(top)]


def report(days: int, root: str) -> dict:
    traces = trace_files(root, days, "traces", "*.jsonl")
    transcripts = trace_files(root, days, "sessions", "*.transcript.jsonl")
    runs = load_events(traces)
    return {"days": days, "runs": len(runs), "transcripts": len(transcripts),
            "tools": tool_table(runs)[:20], "tool_errors_by_model": tool_errors_by_model(runs)[:15],
            "cache": cache_table(runs), "turn_resets": turn_resets(runs),
            "details": counted_details(runs), "refusals": refusal_texts(transcripts)}


def markdown(r: dict) -> str:
    L = [f"# Trajectory report — last {r['days']} days", "",
         f"{r['runs']} runs, {r['transcripts']} saved transcripts. Local only: do not paste into issues.", "",
         "## Tools", "", "| tool | calls | error % | p95 ms |", "|---|---:|---:|---:|"]
    L += [f"| {t['tool']} | {t['calls']} | {t['error_pct']} | {t['p95_ms']} |" for t in r["tools"]]
    L += ["", "## Tool errors by model (30+ calls)", "", "| tool | model | calls | error % |", "|---|---|---:|---:|"]
    L += [f"| {t['tool']} | {t['model']} | {t['calls']} | {t['error_pct']} |" for t in r["tool_errors_by_model"]]
    L += ["", "## Prompt-cache reuse", "", "| model | requests | reuse % | source |", "|---|---:|---:|---|"]
    L += [f"| {c['model']} | {c['requests']} | {c['reuse_pct']} | {c['source']} |" for c in r["cache"]]
    L += ["", "## Cache resets at turn starts", "", "| model | turn boundaries | after idle >10 min | other |", "|---|---:|---:|---:|"]
    L += [f"| {c['model']} | {c['boundaries']} | {c['idle_resets']} | {c['other_resets']} |" for c in r["turn_resets"]]
    L += ["", "## Retries, stalls and open work", ""]
    for ev, rows in r["details"].items():
        L += [f"- **{ev}**: " + "; ".join(f"{n}× {t}" for t, n in rows)]
    L += ["", "## Most common refusals in transcripts", ""]
    L += [f"- {n}× `{tool}`: {text}" for n, tool, text in r["refusals"]]
    L += ["", "Pick eval cases a person would call hard and representative; do not tune prompts to these texts."]
    return "\n".join(L) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--root", default="~")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    r = report(a.days, a.root)
    if a.json:
        print(json.dumps(r, indent=1))
        return
    os.makedirs(LOCAL, exist_ok=True)
    path = os.path.join(LOCAL, f"trajectory-report-{time.strftime('%Y%m%d')}.md")
    with open(path, "w") as f:
        f.write(markdown(r))
    print(path)


if __name__ == "__main__":
    main()
