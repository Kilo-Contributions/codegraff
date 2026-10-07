# Clef compaction experiment: prune vs summary on deepseek-v4-flash

Clone of the `evals/compact_ab` shape, aimed at the Clef gateway arm
(`src/agent_clef_compact.zig`, `GRAFF_CLEF_COMPACT`). Question: on a chat-wire
model where the old server arm is inert, which client-side strategy preserves
audit recall best per dollar — Clef prune, classic summary, two-pass mix,
Clef-then-mix, or nothing?

## Run

```bash
python3 evals/clef_exp/gen_corpus.py   # $CLEF_EXP_DIR/src (default /tmp/clef_exp)
python3 evals/clef_exp/gen_turns.py    # $CLEF_EXP_DIR/turns.txt (13 turns)
bash evals/clef_exp/run_wave.sh wave 5 # one trial per arm in parallel
python3 evals/clef_exp/score_wave.py   # recall + wall + cost from traces
```

`GRAFF_BIN` overrides the binary (default `$HOME/codegraff/zig-out/bin/graff`).
Cost comes from trace `usage` events priced per model row; see `score_wave.py`.

## Arms

| arm | env |
|---|---|
| clef | `GRAFF_CLEF_COMPACT=1 GRAFF_COMPACT_PCT=1` (default off, ADR 0261) |
| client | `GRAFF_CLEF_COMPACT=0 GRAFF_COMPACT_PCT=1` |
| mix | `GRAFF_CLEF_COMPACT=0 GRAFF_COMPACT_MIX=1 GRAFF_COMPACT_PCT=1` |
| clefmix | `GRAFF_CLEF_COMPACT=1 GRAFF_COMPACT_MIX=1 GRAFF_COMPACT_PCT=1` |
| clefarc | `GRAFF_CLEF_COMPACT=1 GRAFF_CLEF_ARCHIVE=1 GRAFF_COMPACT_PCT=1` |
| none | `GRAFF_CLEF_COMPACT=0 GRAFF_COMPACT_PCT=100` |

All arms also set `GRAFF_SERVER_COMPACT=0 GRAFF_TOOL_HANDLE_BYTES=1048576`.

## Results (deepseek-v4-flash, 2 trials/arm, 2026-10-06)

| run | score | clef prunes | wall | api calls | peak input | cost |
|---|---|---|---|---|---|---|
| none5 | 10/10 | — | 133s | 45 | 63K | $0.030 |
| none6 | 10/10 | — | 115s | 52 | 67K | $0.032 |
| clef5 | 10/10 | 1 | 501s | 153 | 31K | $0.185 |
| clef6 | 10/10 | 0 | 716s | 177 | 33K | $0.274 |
| client5 | 10/10 | — | 745s | 204 | 100K | $0.284 |
| client6 | 10/10 | — | 329s | 117 | 51K | $0.111 |
| mix5 | 10/10 | — | 737s | 209 | 40K | $0.251 |
| mix6 | 10/10 | — | 625s | 188 | 26K | $0.225 |
| clefmix5 | 10/10 | 5 | 775s | 209 | 23K | $0.266 |
| clefmix6 | 10/10 | 2 | 836s | 196 | 24K | $0.309 |

Recall tied at 10/10 everywhere at this scale — the task does not separate
recall, only cost and history control.

Read: compacting at all costs 4–9x more than not compacting
(cache-read history at $0.006/1M is nearly free, and every rewrite busts
the cache), matching the earlier `compact_ab` finding on gpt-5.6-sol that
compaction is insurance, not a free lunch. Among compacting arms cost is
comparable; `clefmix` prunes most (5+2) but costs the most.

**Correction (2026-10-07):** an earlier version of this section said client
summaries "pin-degrade" and almost never install. Wrong: `compact_cut`'s
`unresolved:true` is a trace field, and the summary proceeds unless
`pinDegrade` returns `.silent`/`.announce` (`src/agent_compact.zig`). Measured
on the main-agent `usage` line before vs after each `prefix_bust:"compact"`:

| arm | compactions | median shrink | shrank >5% |
|---|---|---|---|
| client summary | 78 | 32% | 55 |
| clef (all models) | 112 | 37% | 92 |
| clefarc (wave 8) | 7 | 41% | 5 |

Most clef-arm compactions are the summary *fallback* after
`clef_compact_noop`, so the clef row is mostly the summary too; Clef's own
prunes installed only a handful of times. The peak-input gap above (23–33K vs
51–100K) is single-trial noise — GLM and Kimi reverse it. The summary is a
working ~1/3 compactor; Clef has not beaten it here.

Caveats: wave-1 exposed and fixed a real bug — partial `drop_call` on a
multi-call assistant message orphaned surviving results and wedged the
session in a gateway-400 loop (`applyDecisions` now degrades partial drops
to truncation, with unit tests on both wires). `clef5`/`clef6`/`mix6` wrote
a correct answer.md but exited without DONE (tail showed a mid-reply
compaction), so `done` is not a reliable signal. Single-prompt runs never
compact twice (compact_cut pin_degrade); the 13-turn shape is load-bearing.

## Cross-model spot-checks (clef/client/none trio, same 13-turn shape)

| run | score | clef prunes | wall | peak input | cost |
|---|---|---|---|---|---|
| glm none | 10/10 | — | 693s | 70K | $0.041 |
| glm clef | 10/10 | 0 | 747s | 77K | $0.062 |
| glm client | 10/10 | — | 859s | 42K | $0.070 |
| kimi none | 10/10 | — | 558s | 99K | $0.348 |
| kimi clef | 10/10 | 1 | 642s | 97K | $0.402 |
| kimi client | 10/10 | — | 864s | 66K | $0.474 |

Same ordering on both models: none cheapest, clef in the middle, client
most expensive — though client summaries DID install (10 of 16 attempts on
kimi-client, 12 of 14 on glm-client; see the correction above) and held
peak input lowest on both. Two model-behavior notes: (1) costs cluster on GLM
because the gateway barely cache-reads it ($0.04–0.07 across arms). (2) Kimi at
$0.95/4 per 1M makes everything ~10x deepseek in absolute terms, but the
relative ordering holds. Driver takes `CLEF_MODEL=` for any codegraff alias
(`trio` mode runs clef/client/none); scorer prices each trace line at its
own model row.

## Archive vs delete (`arc` mode, deepseek-v4-flash, wave 8)

| run | score | clef prunes | peak input | freed | archive reads | cost |
|---|---|---|---|---|---|---|
| none8 | 10/10 | — | 90K | — | — | $0.063 |
| clef8 (delete) | 10/10 | 0 (10 noops → summary) | 53K | 0 | — | $0.070 |
| clefarc8 (archive) | 10/10 | 1 (7 outputs archived) | 76K | 9.9KB | 0 | $0.069 |

Archive mode works end to end (artifacts written, pairing intact, no wedge)
and costs the same, but on this task it barely matters: Clef archived small
1.6–2.6KB outputs and the model never went back for them. This task cannot
separate the arms — every answer value is restated verbatim in assistant
text, which nothing prunes. See the recall variant below.

## Recall variant (`gen_recall.py`, `recall` mode, deepseek-v4-flash, wave 1)

Facts live only in tool output: each turn is `cat src/logs/run-NN.log && rm
…` with a reply of `OK`, then filler, then 10 questions (7 from logs 1–5,
3 controls from logs 3/7/8). Logs are ~20KB, under the per-output cap, so
the #409 send-time spill never fires.

```bash
CLEF_EXP_DIR=/tmp/clef_recall python3 evals/clef_exp/gen_recall.py
CLEF_EXP_DIR=/tmp/clef_recall bash evals/clef_exp/run_wave.sh recall 1
CLEF_EXP_DIR=/tmp/clef_recall python3 evals/clef_exp/score_wave.py
```

| run | score | clef prunes | peak input | cost |
|---|---|---|---|---|
| none1 | 10/10 | — | 102K | $0.047 |
| client1 | 9/10 | — | 63K | $0.120 |
| clef1 | 4/10 | 0 (16 noops → summary) | 55K | $0.089 |
| clefarc1 | 3/10 | 0 (27 noops → summary) | 21K | $0.127 |

Read: Clef pruned nothing on any arm, so every compaction was the summary
fallback and archive mode never engaged — the Clef arms paid for decision
calls that changed nothing. The spread among compacting arms is how hard
the final turn dug, not what compaction kept: client and clef both recovered
values by grepping the session's own `.graff/sessions/*.transcript.jsonl`
(#441), which keeps every tool output whatever compaction does (clef1's grep
returned two correct values it then reported UNKNOWN). client1's one miss is
a log the model refused to run. Graff already has a recoverable archive for
every arm — the transcript — so Clef's archive stub adds a path, not data.
Outcome: ADR 0261, the client summary stays the compactor; Clef is opt-in.
