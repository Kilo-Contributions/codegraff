#!/usr/bin/env python3
"""Autoresearch-style hillclimb for graff vs grok-build.

Propose a harness change, run the same tasks, keep only a measured win
on wall / first-token latency / tool calls / tokens / list-price USD.
Never keep grok-build's heap or a 4-tool catalog (ADR 0024).

    ./hillclimb.py self-test
    ./hillclimb.py score results/run-….jsonl
    ./hillclimb.py decide --champion results/a.jsonl --candidate results/b.jsonl
    ./hillclimb.py iterate --suite core --task exact-reply,fix-fib,file-ops

Held-out loop (ADR 0214): fix a train/test split once, measure noise from
repeated baseline runs, then judge one candidate per round. A candidate is
kept only when its train score beats the noise band AND its test score
improves; train up with test flat is overfitting and is reverted. Only train
failures are ever printed; the test set is scores only.

    ./hillclimb.py split --suite mined [--test-frac 0.33]
    ./hillclimb.py noise --suite mined --harness graff-dev --model gpt-6-sol --reps 3
    ./hillclimb.py round --suite mined --champion graff-dev --candidate graff-dev-x --model gpt-6-sol
"""
from __future__ import annotations

import argparse, hashlib, json, math, os, statistics, subprocess, sys, time

from list_price import attach, self_test as price_self_test

ROOT = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(ROOT, "hillclimb")
CANDIDATES_PATH = os.path.join(LOG_DIR, "candidates.json")
LOG_PATH = os.path.join(LOG_DIR, "log.jsonl")
OURS_DEFAULT = "graff-dev"
THEIRS_DEFAULT = "grok"
AXES = ("wall_s", "first_out_s", "tok_calls", "list_tokens", "list_usd")
# Refuse a "win" that is just grok-build's 165M process (ADR 0024).
HEAP_OURS_KB = 20 * 1024
HEAP_THEIRS_KB = 80 * 1024


def load_jsonl(path: str) -> list[dict]:
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            attach(rec)
            rows.append(rec)
    return rows


def bucket(records: list[dict]) -> dict[str, dict]:
    by: dict[str, dict] = {}
    for r in records:
        b = by.setdefault(r.get("harness") or "?", {
            "n": 0, "ok": 0, "wall_s": 0.0, "first_out_s": 0.0, "first_n": 0,
            "tok_calls": 0, "list_tokens": 0, "list_ordinary": 0, "list_cached": 0,
            "list_out": 0, "list_usd": 0.0, "usd_n": 0, "rss_peak_kb": 0, "tasks": [],
        })
        b["n"] += 1
        b["ok"] += bool(r.get("outcome_ok"))
        b["wall_s"] += r.get("wall_s") or 0
        if r.get("first_out_s") is not None:
            b["first_out_s"] += r["first_out_s"]
            b["first_n"] += 1
        b["tok_calls"] += r.get("tok_calls") or 0
        b["list_tokens"] += r.get("list_tokens") or 0
        b["list_ordinary"] += r.get("list_ordinary") or 0
        b["list_cached"] += r.get("list_cached") or 0
        b["list_out"] += r.get("list_out") or 0
        usd = r.get("list_usd")
        if usd is None:
            usd = r.get("tok_cost_usd")
        if usd is not None:
            b["list_usd"] += usd
            b["usd_n"] += 1
        b["rss_peak_kb"] = max(b["rss_peak_kb"], r.get("rss_peak_kb") or 0)
        b["tasks"].append(r.get("task"))
    for b in by.values():
        b["first_out_s"] = (b["first_out_s"] / b["first_n"]) if b["first_n"] else 0.0
        b["list_usd"] = round(b["list_usd"], 6)
        b["pass"] = f"{b['ok']}/{b['n']}"
    return by


def table(by: dict[str, dict]) -> str:
    hdr = f"{'harness':<22} {'pass':>7} {'wall':>8} {'first':>7} {'calls':>6} {'tokens':>9} {'in':>8} {'cached':>8} {'out':>7} {'list$':>9} {'rss':>8}"
    lines = [hdr]
    for h, b in by.items():
        rss = f"{b['rss_peak_kb'] / 1024:.1f}M" if b["rss_peak_kb"] else "—"
        lines.append(
            f"{h:<22} {b['pass']:>7} {b['wall_s']:>7.1f}s {b['first_out_s']:>6.1f}s "
            f"{b['tok_calls']:>6} {b['list_tokens']:>9} {b['list_ordinary']:>8} "
            f"{b['list_cached']:>8} {b['list_out']:>7} ${b['list_usd']:<8.4f} {rss:>8}"
        )
    return "\n".join(lines)


def _delta(cand: float, champ: float) -> tuple[float, str]:
    if champ == 0 and cand == 0:
        return 0.0, "wash"
    if champ == 0:
        return 1.0, "up"
    rel = (cand - champ) / champ
    if abs(rel) < 0.02:
        return rel, "wash"
    return rel, ("win" if rel < 0 else "loss")


def decide(champ: dict, cand: dict, theirs: dict | None = None, candidate_id: str = "") -> dict:
    """Keep only if pass holds and a majority of axes improve. Cite numbers."""
    reasons = []
    if cand["ok"] < champ["ok"]:
        return {"keep": False, "why": "pass rate dropped", "axes": {}, "champ": champ, "cand": cand}
    if cand["rss_peak_kb"] >= HEAP_THEIRS_KB and champ["rss_peak_kb"] <= HEAP_OURS_KB:
        return {"keep": False, "why": "heap steal (ADR 0024: refuse grok-build RSS)", "axes": {}, "champ": champ, "cand": cand}
    if "4-tool" in (candidate_id or "") or "four-tool" in (candidate_id or ""):
        return {"keep": False, "why": "4-tool catalog is forbidden (ADR 0024)", "axes": {}, "champ": champ, "cand": cand}

    axes = {}
    wins = 0
    for name in AXES:
        rel, verdict = _delta(cand[name], champ[name])
        axes[name] = {"champ": champ[name], "cand": cand[name], "rel": round(rel, 4), "verdict": verdict}
        if verdict == "win":
            wins += 1
        reasons.append(f"{name}: {champ[name]} → {cand[name]} ({verdict}, {rel:+.1%})")

    # Majority of the five named axes, and list-price USD must not get worse
    # unless we also gained a pass.
    keep = cand["ok"] >= champ["ok"] and wins >= 3 and axes["list_usd"]["verdict"] != "loss"
    if axes["list_usd"]["verdict"] == "loss" and cand["ok"] > champ["ok"]:
        keep = wins >= 3
    why = ("keep: " if keep else "drop: ") + "; ".join(reasons)
    out = {"keep": keep, "why": why, "axes": axes, "wins": wins, "champ": {
        k: champ[k] for k in ("pass", "wall_s", "first_out_s", "tok_calls", "list_tokens", "list_usd", "rss_peak_kb")
    }, "cand": {k: cand[k] for k in ("pass", "wall_s", "first_out_s", "tok_calls", "list_tokens", "list_usd", "rss_peak_kb")}}
    if theirs:
        out["theirs"] = {k: theirs[k] for k in ("pass", "wall_s", "first_out_s", "tok_calls", "list_tokens", "list_usd", "rss_peak_kb")}
    return out


def append_log(entry: dict) -> None:
    os.makedirs(LOG_DIR, exist_ok=True)
    entry = dict(entry)
    entry["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(LOG_PATH, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def run_eval(harnesses: str, model: str, suite: str, tasks: list[str] | None, reps: int, jobs: int) -> str:
    # run.py writes each run to its own directory (measurement.isolated_paths);
    # name it here so this loop reads exactly the run it started.
    out_root = os.path.join(ROOT, "results", "hc-" + time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}")
    cmd = [sys.executable, os.path.join(ROOT, "run.py"),
           "--harness", harnesses, "--model", model, "--suite", suite,
           "--reps", str(reps), "-j", str(jobs), "--output-root", out_root]
    if tasks:
        for t in tasks:
            cmd += ["--task", t]
    print("+", " ".join(cmd), flush=True)
    proc = subprocess.run(cmd, cwd=ROOT)
    if proc.returncode != 0:
        raise SystemExit(f"run.py exited {proc.returncode}")
    path = os.path.join(out_root, "results.jsonl")
    if not os.path.exists(path):
        raise SystemExit(f"run.py produced no {path}")
    return path


def cmd_score(args) -> None:
    rows = load_jsonl(args.jsonl)
    by = bucket(rows)
    print(table(by))
    if args.json:
        print(json.dumps(by, indent=2))


def cmd_decide(args) -> None:
    champ_src = load_jsonl(args.champion)
    cand_src = champ_src if args.same_file else load_jsonl(args.candidate)
    cand_name = args.cand_harness or args.ours
    champ_rows = [r for r in champ_src if r.get("harness") == args.ours]
    cand_rows = [r for r in cand_src if r.get("harness") == cand_name]
    theirs_rows = [r for r in cand_src if r.get("harness") == args.theirs]
    if not theirs_rows:
        theirs_rows = [r for r in champ_src if r.get("harness") == args.theirs]
    if not champ_rows or not cand_rows:
        raise SystemExit(f"need rows for {args.ours} and {cand_name}")
    by_c, by_k = bucket(champ_rows), bucket(cand_rows)
    champ, cand = by_c[args.ours], by_k[cand_name]
    theirs = bucket(theirs_rows)[args.theirs] if theirs_rows else None
    print("champion\n" + table(by_c))
    print("\ncandidate\n" + table(by_k))
    if theirs:
        print("\ntheirs\n" + table({args.theirs: theirs}))
    d = decide(champ, cand, theirs, candidate_id=args.candidate_id)
    print("\n" + ("KEEP" if d["keep"] else "DROP"))
    print(d["why"])
    append_log({"kind": "decide", "candidate_id": args.candidate_id, **{k: d[k] for k in d if k != "axes"}, "axes": d["axes"]})
    if args.json:
        print(json.dumps(d, indent=2))


def cmd_iterate(args) -> None:
    with open(CANDIDATES_PATH) as f:
        cands = json.load(f)["candidates"]
    if args.only:
        want = {s.strip() for s in args.only.split(",") if s.strip()}
        cands = [c for c in cands if c["id"] in want]
    else:
        cands = [c for c in cands if not c.get("kept")]
    tasks = [t.strip() for t in (args.task or "").split(",") if t.strip()] or None
    harnesses = [args.ours]
    if args.theirs:
        harnesses.append(args.theirs)
    harnesses += [c["harness"] for c in cands]
    path = run_eval(",".join(harnesses), args.model, args.suite, tasks, args.reps, args.jobs)
    rows = load_jsonl(path)
    by = bucket(rows)
    print("\n" + table(by))
    blocked = []
    if args.theirs and args.theirs not in by:
        blocked.append(f"{args.theirs} produced no rows")
    elif args.theirs:
        theirs_err = [r for r in rows if r.get("harness") == args.theirs and r.get("error")]
        if theirs_err:
            blocked.append(theirs_err[0].get("error") or "theirs error")
    champ = by.get(args.ours)
    if not champ:
        raise SystemExit(f"champion {args.ours} missing from {path}")
    for c in cands:
        cand = by.get(c["harness"])
        if not cand:
            print(f"DROP {c['id']}: no rows")
            append_log({"kind": "iterate", "candidate_id": c["id"], "keep": False, "why": "no rows", "results": path})
            continue
        d = decide(champ, cand, by.get(args.theirs), candidate_id=c["id"])
        print(f"\n{c['id']}: {'KEEP' if d['keep'] else 'DROP'}")
        print(d["why"])
        append_log({"kind": "iterate", "candidate_id": c["id"], "results": path, "blocked": blocked, **d})
    if blocked:
        print("\nblocked-honest:", "; ".join(blocked))


# ── held-out loop (ADR 0214) ─────────────────────────────────────────────

TASKS_DIR = os.path.join(ROOT, "tasks")
GOALS = {"pass": +1, "usd": -1, "wall": -1, "tokens": -1}  # +1: higher is better
STALL_ROUNDS = 3
HEADROOM = 0.95


def suite_tasks(suite: str) -> list[str]:
    ids = []
    for name in sorted(os.listdir(TASKS_DIR)):
        if name.endswith(".json"):
            with open(os.path.join(TASKS_DIR, name)) as f:
                t = json.load(f)
            if t.get("suite") == suite:
                ids.append(t["id"])
    return ids


def make_split(ids: list[str], test_frac: float, seed: str) -> dict:
    if len(ids) < 3:
        raise SystemExit(f"need at least 3 tasks to hold some out, have {len(ids)}")
    order = sorted(ids, key=lambda i: hashlib.sha256(f"{seed}:{i}".encode()).hexdigest())
    n_test = min(len(ids) - 1, max(1, round(len(ids) * test_frac)))
    return {"seed": seed, "test": sorted(order[:n_test]), "train": sorted(order[n_test:])}


def split_path(suite: str) -> str:
    return os.path.join(LOG_DIR, f"split-{suite}.json")


def load_split(suite: str) -> dict:
    path = split_path(suite)
    if not os.path.exists(path):
        raise SystemExit(f"no split for {suite}; run: hillclimb.py split --suite {suite}")
    with open(path) as f:
        return json.load(f)


def metric(rows: list[dict], goal: str) -> float:
    if not rows:
        return 0.0
    if goal == "pass":
        return sum(bool(r.get("outcome_ok")) for r in rows) / len(rows)
    key = {"usd": "list_usd", "wall": "wall_s", "tokens": "list_tokens"}[goal]
    vals = [r.get(key) or 0 for r in rows]
    return sum(vals) / len(vals)


def rep_scores(rows: list[dict], harness: str, tasks: list[str], goal: str) -> list[float]:
    """One score per repetition: the goal metric over that rep's tasks."""
    by_rep: dict[int, list[dict]] = {}
    for r in rows:
        if r.get("harness") == harness and r.get("task") in tasks:
            by_rep.setdefault(int(r.get("rep") or 0), []).append(r)
    return [metric(v, goal) for _, v in sorted(by_rep.items())]


def band(sd: float, reps: int) -> float:
    """Two standard errors of a difference between two `reps`-rep means."""
    return 2 * sd * math.sqrt(2 / max(1, reps))


def noise_summary(rows: list[dict], harness: str, split: dict, reps: int) -> dict:
    out = {"harness": harness, "reps": reps, "sets": {}}
    for name in ("train", "test"):
        entry = {}
        for goal in GOALS:
            scores = rep_scores(rows, harness, split[name], goal)
            sd = statistics.pstdev(scores) if len(scores) > 1 else 0.0
            entry[goal] = {"mean": round(statistics.mean(scores), 6) if scores else 0.0,
                           "rep_sd": round(sd, 6), "band": round(band(sd, reps), 6)}
        flaky = sorted({r["task"] for r in rows if r.get("harness") == harness and r.get("task") in split[name]
                        and len({bool(x.get("outcome_ok")) for x in rows
                                 if x.get("harness") == harness and x.get("task") == r["task"]}) > 1})
        entry["flaky_tasks"] = flaky if name == "train" else len(flaky)  # never name test tasks
        out["sets"][name] = entry
    out["headroom_warning"] = out["sets"]["train"]["pass"]["mean"] >= HEADROOM
    return out


def judge(champ_train: float, cand_train: float, champ_test: float, cand_test: float,
          min_effect: float, goal: str = "pass") -> tuple[bool, str]:
    sign = GOALS[goal]
    d_train = (cand_train - champ_train) * sign
    d_test = (cand_test - champ_test) * sign
    if d_train < -min_effect or d_test < 0:
        return False, f"regressed (train {d_train:+.3f}, test {d_test:+.3f})"
    if d_train > min_effect and d_test > 0:
        return True, f"kept: train {d_train:+.3f} beats the noise band {min_effect:.3f} and test improved {d_test:+.3f}"
    if d_train > min_effect:
        return False, f"overfit: train {d_train:+.3f} improved but test is flat ({d_test:+.3f})"
    return False, f"within noise: train {d_train:+.3f} vs band {min_effect:.3f}"


def stalled(suite: str) -> int:
    """Consecutive non-kept rounds for this suite, most recent first."""
    if not os.path.exists(LOG_PATH):
        return 0
    n = 0
    with open(LOG_PATH) as f:
        rounds = [json.loads(l) for l in f if l.strip()]
    for e in reversed([r for r in rounds if r.get("kind") == "round" and r.get("suite") == suite]):
        if e.get("keep"):
            break
        n += 1
    return n


def cmd_split(args) -> None:
    path = split_path(args.suite)
    if os.path.exists(path) and not args.force:
        raise SystemExit(f"{path} exists; the test set must stay fixed across rounds (--force to redraw)")
    split = make_split(suite_tasks(args.suite), args.test_frac, args.seed)
    split["suite"] = args.suite
    os.makedirs(LOG_DIR, exist_ok=True)
    with open(path, "w") as f:
        json.dump(split, f, indent=1)
        f.write("\n")
    print(f"{args.suite}: {len(split['train'])} train, {len(split['test'])} held out -> {path}")


def cmd_noise(args) -> None:
    split = load_split(args.suite)
    path = run_eval(args.harness, args.model, args.suite, split["train"] + split["test"], args.reps, args.jobs)
    summary = noise_summary(load_jsonl(path), args.harness, split, args.reps)
    summary.update(suite=args.suite, model=args.model, results=path)
    out = os.path.join(LOG_DIR, f"noise-{args.suite}-{args.harness}-{args.model}.json")
    with open(out, "w") as f:
        json.dump(summary, f, indent=1)
        f.write("\n")
    tr = summary["sets"]["train"]
    print(f"train pass {tr['pass']['mean']:.3f} (rep sd {tr['pass']['rep_sd']:.3f}, band {tr['pass']['band']:.3f});"
          f" flaky: {', '.join(tr['flaky_tasks']) or 'none'}")
    if summary["headroom_warning"]:
        print(f"WARNING: baseline is at or above {HEADROOM:.0%} on train; improvements will be hard to see")
    print(f"-> {out}")


def cmd_round(args) -> None:
    split = load_split(args.suite)
    noise_file = os.path.join(LOG_DIR, f"noise-{args.suite}-{args.champion}-{args.model}.json")
    min_effect = args.min_effect
    reps = args.reps
    if min_effect is None and not args.noise_from_round:
        if not os.path.exists(noise_file):
            raise SystemExit(f"no noise measurement ({noise_file}); run hillclimb.py noise first, "
                             "pass --min-effect, or use --noise-from-round")
        with open(noise_file) as f:
            noise = json.load(f)
        min_effect = noise["sets"]["train"][args.goal]["band"]
        reps = reps or noise["reps"]
    reps = reps or (2 if args.noise_from_round else 3)
    if args.noise_from_round and reps < 2:
        raise SystemExit("--noise-from-round needs at least 2 repetitions")
    path = run_eval(f"{args.champion},{args.candidate}", args.model, args.suite,
                    split["train"] + split["test"], reps, args.jobs)
    rows = load_jsonl(path)
    pick = lambda h, s: [r for r in rows if r.get("harness") == h and r.get("task") in split[s]]
    if min_effect is None:
        # The champion's own repetitions in this round give the noise band.
        noise = noise_summary(rows, args.champion, split, reps)
        min_effect = noise["sets"]["train"][args.goal]["band"]
        print(f"noise from this round's champion repetitions: {args.goal} band {min_effect:.4f}")
    for name in ("train", "test"):
        print(f"\n{name}")
        print(table(bucket(pick(args.champion, name) + pick(args.candidate, name))))
    scores = {h: {s: metric(pick(h, s), args.goal) for s in ("train", "test")} for h in (args.champion, args.candidate)}
    keep, why = judge(scores[args.champion]["train"], scores[args.candidate]["train"],
                      scores[args.champion]["test"], scores[args.candidate]["test"], min_effect, args.goal)
    guard = metric(pick(args.candidate, "train"), "pass") < metric(pick(args.champion, "train"), "pass") - min_effect
    if keep and args.goal != "pass" and guard:
        keep, why = False, "pass rate dropped while chasing " + args.goal
    print(f"{args.goal}: champion train {scores[args.champion]['train']:.4f} test {scores[args.champion]['test']:.4f}"
          f" | candidate train {scores[args.candidate]['train']:.4f} test {scores[args.candidate]['test']:.4f}")
    print(("KEEP " if keep else "REVERT ") + why)
    append_log({"kind": "round", "suite": args.suite, "goal": args.goal, "candidate_id": args.candidate_id or args.candidate,
                "champion": args.champion, "candidate": args.candidate, "model": args.model, "reps": reps,
                "min_effect": min_effect, "scores": scores, "keep": keep, "why": why, "results": path})
    n = stalled(args.suite)
    if n >= STALL_ROUNDS:
        print(f"\nstalled: {n} rounds without a kept change. Analyze what still fails on TRAIN by root cause:")
        for r in pick(args.champion, "train"):
            if not r.get("outcome_ok"):
                print(f"  {r['task']} rep {r.get('rep')}: {(r.get('check_note') or r.get('error') or '')[:160]}")
        print("If no single fix could beat the noise band, add repetitions or tasks instead of more rounds.")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("self-test")
    p.set_defaults(fn=lambda _: (price_self_test(), _decide_self_test(), _heldout_self_test(), print("hillclimb self-test ok")))

    p = sub.add_parser("score")
    p.add_argument("jsonl")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_score)

    p = sub.add_parser("decide")
    p.add_argument("--champion", required=True)
    p.add_argument("--candidate", default=None)
    p.add_argument("--same-file", action="store_true")
    p.add_argument("--ours", default=OURS_DEFAULT)
    p.add_argument("--cand-harness", default=None)
    p.add_argument("--theirs", default=THEIRS_DEFAULT)
    p.add_argument("--candidate-id", default="")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_decide)

    p = sub.add_parser("iterate")
    p.add_argument("--ours", default=OURS_DEFAULT)
    p.add_argument("--theirs", default=THEIRS_DEFAULT)
    p.add_argument("--model", default="grok-4.6")
    p.add_argument("--suite", default="core")
    p.add_argument("--task", default="")
    p.add_argument("--reps", type=int, default=1)
    p.add_argument("--jobs", "-j", type=int, default=1)
    p.add_argument("--only", default="")
    p.set_defaults(fn=cmd_iterate)

    p = sub.add_parser("split")
    p.add_argument("--suite", required=True)
    p.add_argument("--test-frac", type=float, default=0.33)
    p.add_argument("--seed", default="graff")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_split)

    p = sub.add_parser("noise")
    p.add_argument("--suite", required=True)
    p.add_argument("--harness", default=OURS_DEFAULT)
    p.add_argument("--model", default="grok-4.6")
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--jobs", "-j", type=int, default=1)
    p.set_defaults(fn=cmd_noise)

    p = sub.add_parser("round")
    p.add_argument("--suite", required=True)
    p.add_argument("--champion", default=OURS_DEFAULT)
    p.add_argument("--candidate", required=True)
    p.add_argument("--candidate-id", default="")
    p.add_argument("--model", default="grok-4.6")
    p.add_argument("--goal", choices=sorted(GOALS), default="pass")
    p.add_argument("--reps", type=int, default=None)
    p.add_argument("--min-effect", type=float, default=None)
    p.add_argument("--noise-from-round", action="store_true",
                   help="take the noise band from the champion's repetitions in this round (no separate baseline)")
    p.add_argument("--jobs", "-j", type=int, default=1)
    p.set_defaults(fn=cmd_round)

    args = ap.parse_args()
    if args.cmd == "decide" and not args.candidate and not args.same_file:
        ap.error("decide needs --candidate or --same-file")
    if args.cmd == "decide" and args.same_file:
        args.candidate = args.champion
    args.fn(args)


def _decide_self_test() -> None:
    champ = {"ok": 3, "n": 3, "pass": "3/3", "wall_s": 30.0, "first_out_s": 2.0,
             "tok_calls": 10, "list_tokens": 20_000, "list_usd": 0.05, "rss_peak_kb": 9000}
    better = dict(champ, wall_s=20.0, tok_calls=6, list_tokens=12_000, list_usd=0.03, first_out_s=1.5)
    d = decide(champ, better)
    assert d["keep"], d
    worse = dict(champ, ok=2, wall_s=10.0, list_usd=0.01)
    d = decide(champ, worse)
    assert not d["keep"]
    heap = dict(better, rss_peak_kb=170_000)
    d = decide(champ, heap)
    assert not d["keep"]
    catalog = decide(champ, better, candidate_id="four-tool-copy")
    assert not catalog["keep"]



def _heldout_self_test() -> None:
    ids = [f"t{i}" for i in range(12)]
    a, b = make_split(ids, 0.33, "graff"), make_split(list(reversed(ids)), 0.33, "graff")
    assert a == b, "split must not depend on listing order"
    assert not set(a["train"]) & set(a["test"]) and sorted(a["train"] + a["test"]) == sorted(ids)
    assert len(a["test"]) == 4
    assert make_split(ids, 0.33, "other") != a
    rows = [{"harness": "h", "task": t, "rep": rep, "outcome_ok": not (t == "t0" and rep == 1)}
            for rep in range(3) for t in ids]
    split = {"train": [t for t in ids if t != "t11"], "test": ["t11"]}
    n = noise_summary(rows, "h", split, 3)
    assert n["sets"]["train"]["pass"]["rep_sd"] > 0 and n["sets"]["test"]["pass"]["rep_sd"] == 0
    assert n["sets"]["train"]["flaky_tasks"] == ["t0"] and n["headroom_warning"]
    keep, why = judge(0.60, 0.80, 0.50, 0.60, 0.05)
    assert keep, why
    keep, why = judge(0.60, 0.80, 0.50, 0.50, 0.05)
    assert not keep and why.startswith("overfit"), why
    keep, why = judge(0.60, 0.62, 0.50, 0.60, 0.05)
    assert not keep and why.startswith("within noise"), why
    keep, why = judge(0.60, 0.70, 0.50, 0.40, 0.05)
    assert not keep and why.startswith("regressed"), why
    keep, why = judge(0.050, 0.030, 0.050, 0.040, 0.005, goal="usd")
    assert keep, why


if __name__ == "__main__":
    main()
