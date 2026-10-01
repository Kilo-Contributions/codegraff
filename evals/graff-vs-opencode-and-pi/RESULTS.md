# graff vs OpenCode 2 and pi on a gateway model

Measured 2026-10-01. One model, served through the Codegraff gateway's chat-completions endpoint, ran the same 21 tasks in each harness, side by side, on one machine and one gateway key.

| Arm | What ran |
| --- | --- |
| graff | The ADR 0231 build (#1449) as a scripted `graff repl` (the `graff-gateway-repl` harness). |
| OpenCode 2 | `@opencode/cli` 2.0.21: `opencode run --standalone --auto --format json`, through [`graff-evals/opencode2_run.py`](../../graff-evals/opencode2_run.py). |
| pi | pi 0.84.2 (the `pi-codegraff` harness). pi has no MCP client, so it ran the 11 coding tasks only. |

All three send the same model id to the same endpoint, and each runs at its own defaults.

## Results

All 21 tasks (pi: the 11 coding tasks), mean per task over 3 runs of each:

| | Pass | Wall per task | Input read from cache | Output tokens per task | Model calls per task |
| --- | ---: | ---: | ---: | ---: | ---: |
| graff (ADR 0231 build) | 63/63 | 9.1s | 94% | 582 | 3.6 |
| OpenCode 2 | 62/63 | 14.4s | 86% | 980 | 4.2 |
| pi | 33/33 | 5.4s | 78% | 258 | 2.7 |

By suite:

| Suite | graff (ADR 0231 build) | OpenCode 2 | pi |
| --- | ---: | ---: | ---: |
| core (11 coding tasks), wall | 7.3s | 6.9s | 5.4s |
| core (11 coding tasks), pass | 33/33 | 33/33 | 33/33 |
| mcp (10 MCP tasks), wall | 11.0s | 22.6s | — |
| mcp (10 MCP tasks), pass | 30/30 | 29/30 | — |

**Against OpenCode 2.** graff is 37% faster per task over all 21 tasks (9.1s against 14.4s). The gap is the MCP tasks, which graff finishes in about half the time (11.0s against 22.6s), with 4.4 model calls to 5.3 and 917 output tokens to 1,655: graff slims large list results and often fetches, reduces and writes the report in one `rlm` script. On the coding tasks OpenCode 2 is slightly faster (6.9s against 7.3s). OpenCode 2 failed one run: on one `linear-split` run it ended while still waiting for its two sub-agents, without writing `report.json`.

**Against pi.** pi is the fastest on the coding tasks (5.4s against graff's 7.3s), with a much smaller prompt and the fewest calls (2.7 per task). It has no MCP client, so it has no MCP result.

graff reads the most of its input from cache (94%, against 86% for OpenCode 2 and 78% for pi).

## Per task

Wall time is the mean of 3 runs.

| Task | Suite | graff (ADR 0231 build) | OpenCode 2 | pi |
| --- | --- | ---: | ---: | ---: |
| [`csv-sum`](../../graff-evals/tasks/11-csv-sum.json) | core | 9.5s | 7.8s | 5.0s |
| [`dead-code`](../../graff-evals/tasks/12-dead-code.json) | core | 6.9s | 6.8s | 6.0s |
| [`exact-reply`](../../graff-evals/tasks/01-exact-reply.json) | core | 1.8s | 2.1s | 1.7s |
| [`file-ops`](../../graff-evals/tasks/03-file-ops.json) | core | 4.2s | 5.9s | 4.6s |
| [`fix-fib`](../../graff-evals/tasks/02-fix-fib.json) | core | 8.1s | 7.6s | 7.6s |
| [`git-ops`](../../graff-evals/tasks/08-git-ops.json) | core | 6.1s | 6.2s | 4.6s |
| [`json-transform`](../../graff-evals/tasks/04-json-transform.json) | core | 5.5s | 6.0s | 5.6s |
| [`linear-issues`](../../graff-evals/tasks/24-linear-issues.json) | mcp | 7.5s | 30.4s | — |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | mcp | 10.0s | 20.2s | — |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | mcp | 9.9s | 20.4s | — |
| [`linear-quiet`](../../graff-evals/tasks/28-linear-quiet.json) | mcp | 11.3s | 20.2s | — |
| [`linear-quiet-warm`](../../graff-evals/tasks/29-linear-quiet-warm.json) | mcp | 15.7s | 21.5s | — |
| [`linear-reduce`](../../graff-evals/tasks/32-linear-reduce.json) | mcp | 9.5s | 20.9s | — |
| [`linear-reduce-warm`](../../graff-evals/tasks/33-linear-reduce-warm.json) | mcp | 8.8s | 19.2s | — |
| [`linear-sidecar`](../../graff-evals/tasks/26-linear-sidecar.json) | mcp | 8.9s | 22.5s | — |
| [`linear-split`](../../graff-evals/tasks/27-linear-split.json) | mcp | 18.9s | 30.0s (2/3) | — |
| [`linear-warm`](../../graff-evals/tasks/25-linear-warm.json) | mcp | 9.1s | 20.6s | — |
| [`recall-noise`](../../graff-evals/tasks/09-recall-noise.json) | core | 7.8s | 7.6s | 4.4s |
| [`refactor-rename`](../../graff-evals/tasks/06-refactor-rename.json) | core | 10.3s | 8.6s | 7.8s |
| [`regex-count`](../../graff-evals/tasks/05-regex-count.json) | core | 14.1s | 8.6s | 6.0s |
| [`write-tests`](../../graff-evals/tasks/07-write-tests.json) | core | 6.6s | 8.4s | 6.1s |

`results.json` has every run: pass, wall time, model calls, and input, cached input and output tokens.

## Method

- **Tasks.** 11 coding tasks (`core`) and 10 tasks against a Linear-shaped MCP server (`mcp`, [`scripts/linear_fixture_mcp.py`](../../scripts/linear_fixture_mcp.py)), from [`graff-evals/tasks`](../../graff-evals/tasks). OpenCode 2 does not read `.mcp.json`; its wrapper writes the same server into the task's `opencode.json`. Each task passes or fails on its own check.
- **Order.** 3 runs per task and arm. graff and OpenCode 2 were interleaved task by task (`run.py --interleave`), 6 runs at a time; pi ran its coding tasks afterwards. Each arm made one unscored request first.
- **Wall time.** The runner's clock around each process, start to exit.
- **Tokens.** Prompt tokens include cached ones in every arm. OpenCode 2's come from its own session database (`session_v2`), whose input count leaves out cache reads and writes, so the wrapper adds them back. No list cost: the gateway's prices are not public list prices.

## Caveats

- **pi runs only the coding tasks.** It has no MCP client.
- **One model.** Harness differences can look different on another model; the [Codex comparison](../graff-vs-codex-app-server/RESULTS.md) runs graff and pi on a different one.
- **Small sample.** 3 runs per task, one machine, one key. A second or two per task is within run-to-run noise.

## Reproduce

```sh
cd graff-evals
# CODEGRAFF_API_KEY set; OpenCode 2 needs a `codegraff` provider in its config
# (openai-compatible, baseURL https://gateway.codegraff.com/v1, apiKey {env:CODEGRAFF_API_KEY})
# and OPENCODE2_BIN when `opencode` on PATH is 1.x; pi needs the `codegraff`
# provider in ~/.pi/agent/models.json. Keep --output-root outside any repository,
# with scripts/linear_fixture_mcp.py copied to <parent of output-root>/scripts/.
TASKS="--task exact-reply --task fix-fib --task file-ops --task json-transform --task regex-count \
  --task refactor-rename --task write-tests --task git-ops --task recall-noise --task csv-sum \
  --task dead-code --task linear-issues --task linear-warm --task linear-sidecar \
  --task linear-split --task linear-quiet --task linear-quiet-warm --task linear-nohint \
  --task linear-nohint-warm --task linear-reduce --task linear-reduce-warm"
python3 run.py --harness graff-gateway-repl,opencode2 --model <gateway model> --suite core,mcp $TASKS \
  --reps 3 -j 6 --interleave --output-root /path/outside/repo/gateway
python3 run.py --harness pi-codegraff --model <gateway model> --suite core $TASKS \
  --reps 3 -j 6 --output-root /path/outside/repo/gateway-pi
```
