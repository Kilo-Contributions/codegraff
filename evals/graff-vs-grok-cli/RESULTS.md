# graff vs the Grok CLI

Measured 2026-10-01. One machine and one SuperGrok account ran the same 21
tasks in each harness, side by side.

| Arm | What ran |
| --- | --- |
| graff v0.0.302.12 | The published release asset, checked against the release's `SHA256SUMS`, with `--model xai/grok-4.7` on the `graff login xai` sign-in. |
| Grok CLI | `grok` 1.0.41 (Grok Build) with `-m grok-4.7`, headless: `-p … --always-approve --output-format streaming-messages-json`. |

Both sign in through the same xAI OAuth client to the same account, and both
run at their own defaults. The model is not quite the same: asked for
`grok-4.7`, the Grok CLI's route serves `grok-4.7-build`, a variant only that
route offers. graff uses xAI's public API, which serves `grok-4.7` and has no
build variant.

## Results

All 21 tasks, mean per task over 3 runs of each:

| | Pass | Wall per task | List cost per task | Prompt tokens per task | Input read from cache | Output tokens per task | Model calls per task |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| graff v0.0.302.12 | 63/63 | 15.5s | $0.039 | 29,696 | 57% | 823 | 4.3 |
| Grok CLI | 54/63 | 106.9s | $0.33\* | 466,465\* | 90%\* | 4,007\* | 10.4\* |

\* Over the 50 Grok runs that reported usage. The 13 runs stopped at the
240-second time limit left no usage record; they ran longest, so these
figures are likely low. Counting those runs as free gives $0.26 per task.

By suite:

| Suite | graff v0.0.302.12 | Grok CLI |
| --- | ---: | ---: |
| core (11 coding tasks), wall | 6.6s | 14.8s |
| core (11 coding tasks), cost | $0.0215 | $0.0578 |
| core (11 coding tasks), pass | 33/33 | 33/33 |
| mcp (10 MCP tasks), wall | 25.3s | 208.4s |
| mcp (10 MCP tasks), cost | $0.058 | $0.86\* |
| mcp (10 MCP tasks), pass | 30/30 | 21/30 |

**Coding tasks.** Both pass every run. graff takes less than half the time
per task (6.6s against 14.8s) and costs 63% less.

**MCP tasks.** graff is about 8 times faster (25.3s against 208.4s per task).
The Grok CLI failed 9 runs, all at the time limit, including every
`linear-split` run, where its two sub-agents never finished. Four more Grok
runs hit the limit after writing a correct report; they count as passes. Its
MCP runs that reported usage averaged 23.5 model calls and 1.24M prompt
tokens per task, because every turn re-sends the full MCP results. graff
slims list results, batches the calls in one script, and averaged 5.7 calls
and 41k prompt tokens.

**Cost.** At grok-4.7's public list price, graff costs 85% to 88% less per
task ($0.039 against $0.26 to $0.33). xAI's own figure for the Grok CLI's
build-model route is $0.098 per task; graff is 60% below that even at the
higher public price.

**Where the Grok CLI does better.** It reads more of its input from cache (90%
against graff's 57%). graff still sends about a quarter as many uncached
tokens per task (12.9k against 48.9k).

## Per task

Wall time is the mean of 3 runs.

| Task | Suite | graff v0.0.302.12 | Grok CLI |
| --- | --- | ---: | ---: |
| [`csv-sum`](../../graff-evals/tasks/11-csv-sum.json) | core | 6.2s | 18.5s |
| [`dead-code`](../../graff-evals/tasks/12-dead-code.json) | core | 5.0s | 12.3s |
| [`exact-reply`](../../graff-evals/tasks/01-exact-reply.json) | core | 2.0s | 5.0s |
| [`file-ops`](../../graff-evals/tasks/03-file-ops.json) | core | 5.2s | 7.1s |
| [`fix-fib`](../../graff-evals/tasks/02-fix-fib.json) | core | 9.6s | 17.0s |
| [`git-ops`](../../graff-evals/tasks/08-git-ops.json) | core | 8.5s | 16.7s |
| [`json-transform`](../../graff-evals/tasks/04-json-transform.json) | core | 5.8s | 16.4s |
| [`linear-issues`](../../graff-evals/tasks/24-linear-issues.json) | mcp | 19.7s | 173.0s |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | mcp | 24.5s | 214.5s (2/3) |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | mcp | 20.0s | 189.9s |
| [`linear-quiet`](../../graff-evals/tasks/28-linear-quiet.json) | mcp | 21.3s | 208.1s (2/3) |
| [`linear-quiet-warm`](../../graff-evals/tasks/29-linear-quiet-warm.json) | mcp | 23.1s | 203.9s (2/3) |
| [`linear-reduce`](../../graff-evals/tasks/32-linear-reduce.json) | mcp | 21.3s | 214.5s |
| [`linear-reduce-warm`](../../graff-evals/tasks/33-linear-reduce-warm.json) | mcp | 14.9s | 210.9s (2/3) |
| [`linear-sidecar`](../../graff-evals/tasks/26-linear-sidecar.json) | mcp | 46.7s | 233.3s (2/3) |
| [`linear-split`](../../graff-evals/tasks/27-linear-split.json) | mcp | 42.5s | 240.5s (0/3) |
| [`linear-warm`](../../graff-evals/tasks/25-linear-warm.json) | mcp | 18.7s | 194.9s (2/3) |
| [`recall-noise`](../../graff-evals/tasks/09-recall-noise.json) | core | 4.0s | 7.3s |
| [`refactor-rename`](../../graff-evals/tasks/06-refactor-rename.json) | core | 8.4s | 18.8s |
| [`regex-count`](../../graff-evals/tasks/05-regex-count.json) | core | 10.8s | 26.4s |
| [`write-tests`](../../graff-evals/tasks/07-write-tests.json) | core | 6.6s | 16.8s |

graff passed every run; Grok's passes are 3/3 unless shown. `results.json` has
every run: pass, wall time, model calls, prompt, cached and output tokens,
list cost, and xAI's reported cost for the Grok runs.

## Method

- **Tasks.** 11 coding tasks (`core`) and 10 tasks against a Linear-shaped MCP server (`mcp`, [`scripts/linear_fixture_mcp.py`](../../scripts/linear_fixture_mcp.py)), from [`graff-evals/tasks`](../../graff-evals/tasks). The Grok CLI reads the task's `.mcp.json` itself. Each task passes or fails on its own check, within its 240-second limit.
- **Order.** 3 runs per task and arm, arms interleaved task by task (`run.py --interleave`), 6 runs at a time. Each arm made one unscored request first.
- **Isolation.** Both ran with a fresh `HOME`, so neither saw user-level MCP servers or rules. The Grok CLI's `GROK_HOME` pointed at its signed-in config directory.
- **Wall time.** The runner's clock around each process, start to exit.
- **Tokens.** Prompt tokens include cached tokens for both arms (the Grok CLI's stream reports them separately). A Grok run stopped at the time limit has no result event; its tokens come from the Grok session's own usage record when one exists.
- **Cost.** List price of each run's tokens at grok-4.7's public rates: $2 per 1M input, $0.50 per 1M cached input, $6 per 1M output ([`graff-evals/list_price.py`](../../graff-evals/list_price.py)). No request in either arm reached the 200k-token higher price band (the largest Grok context was 93.6k). A SuperGrok plan is not billed per token; this makes the harnesses comparable, not a bill.

## Caveats

- **Different model variants.** The Grok CLI ran `grok-4.7-build` on its own route, graff ran `grok-4.7` on the public API.
- **Missing Grok usage.** 13 Grok runs, all MCP, were stopped at the time limit without a usage record, so Grok's token and cost means cover the other 50 runs.
- **Every task runs in a fresh git repository.** A session that stays in one repository sees fewer cold first requests in either harness.
- **Small sample.** 3 runs per task, one machine, one account, one run.

## Reproduce

```sh
cd graff-evals
# Two arms in harnesses.json (local, not committed):
#   graff:    ["<graff>", "-p", "{prompt}", "--model", "{model}", "--yolo"], usage graff-stderr,
#             default_model "xai/grok-4.7"
#   grok-cli: ["grok", "-p", "{prompt}", "-m", "{model}", "--always-approve",
#              "--output-format", "streaming-messages-json"], answer/usage grok-stream,
#             env GROK_HOME=<signed-in grok config dir>, default_model "grok-4.7"
# Run with HOME set to an empty directory; graff needs its xAI sign-in reachable there.
# Keep --output-root outside any repository, with scripts/linear_fixture_mcp.py
# copied to <parent of output-root>/scripts/ for the mcp suite.
python3 run.py --harness graff,grok-cli --suite core,mcp --reps 3 -j 6 --interleave \
  --output-root /path/outside/repo/run \
  --task exact-reply --task fix-fib --task file-ops --task json-transform --task regex-count \
  --task refactor-rename --task write-tests --task git-ops --task recall-noise --task csv-sum \
  --task dead-code --task linear-issues --task linear-warm --task linear-sidecar \
  --task linear-split --task linear-quiet --task linear-quiet-warm --task linear-nohint \
  --task linear-nohint-warm --task linear-reduce --task linear-reduce-warm
```
