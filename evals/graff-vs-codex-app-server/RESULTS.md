# graff vs the Codex app server and pi

Measured 2026-10-01. The same model (`gpt-6.1-sol`), ChatGPT account and machine ran the same 21 tasks in each harness, side by side.

| Arm | What ran |
| --- | --- |
| graff | The ADR 0231 build (#1449: the `perf: drop round trips the model does not need` commit on top of v0.0.302.12), as a scripted `graff repl` over the Codex Responses WebSocket. |
| Codex app server | `codex app-server` from codex-cli 0.159.0, through [`graff-evals/codex_app_server.py`](../../graff-evals/codex_app_server.py). |
| pi | pi 0.84.2 on the ChatGPT plan (`--provider openai-codex`). pi has no MCP client, so it ran the 11 coding tasks only. |

Each harness runs at the model catalog's default, `low` effort (pi's `--thinking low`). graff sends the prompt as one bracketed-paste frame, so a task with a line break is one turn, as it is for the other two.

## Results

All 21 tasks (pi: the 11 coding tasks), mean per task over 3 runs of each:

| | Pass | Wall per task | List cost per task | Input read from cache | Output tokens per task | Model calls per task |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| graff (ADR 0231 build) | 63/63 | 22.2s | $0.0131 | 90% | 348 | 3.1 |
| Codex app server | 63/63 | 28.6s | $0.0426 | 86% | 409 | 4.4 |
| pi | 33/33 | 17.0s | $0.0067 | 33% | 107 | 3.2 |

By suite:

| Suite | graff (ADR 0231 build) | Codex app server | pi |
| --- | ---: | ---: | ---: |
| core (11 coding tasks), wall | 16.0s | 20.4s | 17.0s |
| core (11 coding tasks), cost | $0.0093 | $0.0156 | $0.0067 |
| core (11 coding tasks), pass | 33/33 | 33/33 | 33/33 |
| mcp (10 MCP tasks), wall | 29.0s | 37.8s | — |
| mcp (10 MCP tasks), cost | $0.0173 | $0.0722 | — |
| mcp (10 MCP tasks), pass | 30/30 | 30/30 | — |

**Against the Codex app server.** graff is 22% faster per task over all 21 tasks (22.2s against 28.6s): 22% on the coding tasks (16.0s against 20.4s) and 23% on the MCP tasks (29.0s against 37.8s). It makes 3.1 model calls per task to the app server's 4.4, and 3.3 to its 5.8 on the MCP tasks, where a single `rlm` script often fetches, reduces and writes the report. It costs 69% less per task on the app server's own reported usage ($0.0131 against $0.0426). Every arm passed every run.

**Against pi.** On the coding tasks graff is 6% faster (16.0s against 17.0s). pi's system prompt is about a tenth of graff's, so it sends far fewer tokens and costs less per coding task ($0.0067 against $0.0093); it reads little from cache.

**Against the release.** Earlier the same afternoon, in a run interleaved the same way, v0.0.302.12 took 27.1s per task and the app server 27.4s; on the MCP tasks the release was slower (38.1s against 36.6s, 5.9 calls to 5.8). The ADR 0231 build is 18% faster than the release (22.2s against 27.1s) and 23% cheaper ($0.0131 against $0.0171). That run is [`release-baseline.json`](release-baseline.json).

## Per task

Wall time is the mean of 3 runs.

| Task | Suite | graff (ADR 0231 build) | Codex app server | pi |
| --- | --- | ---: | ---: | ---: |
| [`csv-sum`](../../graff-evals/tasks/11-csv-sum.json) | core | 16.0s | 21.5s | 13.8s |
| [`dead-code`](../../graff-evals/tasks/12-dead-code.json) | core | 10.6s | 21.0s | 18.2s |
| [`exact-reply`](../../graff-evals/tasks/01-exact-reply.json) | core | 5.0s | 8.3s | 8.5s |
| [`file-ops`](../../graff-evals/tasks/03-file-ops.json) | core | 14.5s | 13.1s | 23.0s |
| [`fix-fib`](../../graff-evals/tasks/02-fix-fib.json) | core | 21.4s | 23.5s | 22.3s |
| [`git-ops`](../../graff-evals/tasks/08-git-ops.json) | core | 21.5s | 20.4s | 15.5s |
| [`json-transform`](../../graff-evals/tasks/04-json-transform.json) | core | 16.8s | 30.6s | 15.2s |
| [`linear-issues`](../../graff-evals/tasks/24-linear-issues.json) | mcp | 22.8s | 26.8s | — |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | mcp | 30.7s | 28.5s | — |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | mcp | 27.8s | 34.2s | — |
| [`linear-quiet`](../../graff-evals/tasks/28-linear-quiet.json) | mcp | 22.0s | 36.6s | — |
| [`linear-quiet-warm`](../../graff-evals/tasks/29-linear-quiet-warm.json) | mcp | 24.0s | 33.4s | — |
| [`linear-reduce`](../../graff-evals/tasks/32-linear-reduce.json) | mcp | 22.5s | 39.2s | — |
| [`linear-reduce-warm`](../../graff-evals/tasks/33-linear-reduce-warm.json) | mcp | 26.6s | 37.7s | — |
| [`linear-sidecar`](../../graff-evals/tasks/26-linear-sidecar.json) | mcp | 38.3s | 35.4s | — |
| [`linear-split`](../../graff-evals/tasks/27-linear-split.json) | mcp | 52.5s | 66.4s | — |
| [`linear-warm`](../../graff-evals/tasks/25-linear-warm.json) | mcp | 23.0s | 39.4s | — |
| [`recall-noise`](../../graff-evals/tasks/09-recall-noise.json) | core | 9.9s | 10.5s | 10.3s |
| [`refactor-rename`](../../graff-evals/tasks/06-refactor-rename.json) | core | 23.0s | 29.0s | 23.4s |
| [`regex-count`](../../graff-evals/tasks/05-regex-count.json) | core | 17.2s | 18.0s | 13.3s |
| [`write-tests`](../../graff-evals/tasks/07-write-tests.json) | core | 20.4s | 28.1s | 23.8s |

`results.json` has every run: pass, wall time, model calls, input, cached input and output tokens, and list cost.

## Method

- **Tasks.** 11 coding tasks (`core`) and 10 tasks against a Linear-shaped MCP server (`mcp`, [`scripts/linear_fixture_mcp.py`](../../scripts/linear_fixture_mcp.py)), from [`graff-evals/tasks`](../../graff-evals/tasks). The fixture declares its two list tools read-only (`readOnlyHint`). Each task passes or fails on its own check.
- **Order.** 3 runs per task and arm, arms interleaved task by task (`run.py --interleave`), 8 runs at a time; the MCP suite ran first, then the coding suite with pi added. Each arm made one unscored request first, so no arm started with a prompt cache the others had warmed.
- **Wall time.** The runner's clock around each process, start to exit.
- **Cost.** List price of the tokens each harness reports: $2 per 1M input, $0.10 per 1M cached input and $10 per 1M output ([`graff-evals/list_price.py`](../../graff-evals/list_price.py)). The app server's three `linear-split` runs total more than 272k input tokens, the model's higher-price threshold, across 16 to 18 requests averaging 22k to 25k each; no single request comes near it, so they are priced at the standard rates. A ChatGPT plan is not billed per token; this makes the harnesses comparable, not a bill.

## Caveats

- **Codex's reported usage leaves out one request.** Before a thread's first turn the app server sends a warm-up request (`generate: false`) with its instructions and tools, about 12k tokens. Its usage is not reported, so the Codex cost above is a floor.
- **pi runs only the coding tasks.** It has no MCP client.
- **Every task runs in a fresh git repository.** A session that stays in one repository sees fewer cold first requests in every harness.
- **Small sample.** 3 runs per task, one machine, one account. A few seconds per task is within run-to-run noise.

## Reproduce

```sh
cd graff-evals
# graff-repl runs {repo}/zig-out/bin/graff (it needs the piped paste of ADR 0231);
# --binary points it elsewhere. The app server needs `codex` on PATH and CODEX_HOME at a
# signed-in Codex home. pi-codex needs pi signed in on the ChatGPT plan, with gpt-6.1-sol
# declared under providers.openai-codex.models in ~/.pi/agent/models.json.
# Keep --output-root outside any repository, with scripts/linear_fixture_mcp.py copied to
# <parent of output-root>/scripts/ for the mcp suite.
TASKS="--task exact-reply --task fix-fib --task file-ops --task json-transform --task regex-count \
  --task refactor-rename --task write-tests --task git-ops --task recall-noise --task csv-sum \
  --task dead-code --task linear-issues --task linear-warm --task linear-sidecar \
  --task linear-split --task linear-quiet --task linear-quiet-warm --task linear-nohint \
  --task linear-nohint-warm --task linear-reduce --task linear-reduce-warm"
python3 run.py --harness graff-repl,codex-app-server --suite mcp $TASKS \
  --reps 3 -j 8 --interleave --output-root /path/outside/repo/mcp
python3 run.py --harness graff-repl,codex-app-server,pi-codex --suite core $TASKS \
  --reps 3 -j 8 --interleave --output-root /path/outside/repo/core
```
