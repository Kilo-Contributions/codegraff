# graff vs the Codex app server

Measured 2026-10-01. The same model (`gpt-6.1-sol`), ChatGPT account and machine ran the same 21 tasks in each harness, side by side.

| Arm | What ran |
| --- | --- |
| graff v0.0.302.11 | The published release asset, checked against the release's `SHA256SUMS`. |
| graff main | Main at `900e62d9`: v0.0.302.11 plus #1438, #1439 and #1440 (ADR 0226, 0227, 0228). |
| Codex app server | `codex app-server` from codex-cli 0.159.0. |

graff runs as a scripted `graff repl` over the Codex Responses WebSocket, the transport the app server uses (the `graff-codex-repl` harness). The app server runs through [`graff-evals/codex_app_server.py`](../../graff-evals/codex_app_server.py), which drives its JSON-RPC and reads the token usage it reports. Each harness uses its own defaults. For this model that means `low` effort and `low` verbosity for graff main and for the app server (the model catalog's defaults), and `medium` effort for v0.0.302.11.

## Results

All 21 tasks, mean per task over 3 runs of each:

| | Pass | Wall per task | List cost per task | Input read from cache | Output tokens per task | Model calls per task |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| graff v0.0.302.11 | 63/63 | 31.2s | $0.0189 | 92% | 598 | 4.7 |
| graff main | 63/63 | 28.2s | $0.0164 | 93% | 490 | 4.7 |
| Codex app server | 63/63 | 25.0s | $0.0278 | 86% | 382 | 4.3 |

By suite:

| Suite | graff v0.0.302.11 | graff main | Codex app server |
| --- | ---: | ---: | ---: |
| core (11 coding tasks), wall | 17.3s | 17.5s | 17.6s |
| core (11 coding tasks), cost | $0.0078 | $0.0081 | $0.0148 |
| core (11 coding tasks), pass | 33/33 | 33/33 | 33/33 |
| mcp (10 MCP tasks), wall | 46.5s | 40.0s | 33.0s |
| mcp (10 MCP tasks), cost | $0.0311 | $0.0256 | $0.0436 |
| mcp (10 MCP tasks), pass | 30/30 | 30/30 | 30/30 |

**Against the release.** graff main is 10% faster and 13% cheaper per task than v0.0.302.11. The gain is in the MCP suite (46.5s to 40.0s per task, $0.0311 to $0.0256), most of it on `linear-split` (114.6s to 65.7s), where sub-agents now call the tools their root loaded (ADR 0227, 0228). The core suite is unchanged.

**Against the Codex app server.** graff main ties on the core suite (17.5s against 17.6s) and is slower on the MCP suite (40.0s against 33.0s). Per MCP task it makes 6.1 model calls to the app server's 5.8 and writes 789 output tokens to its 575; `linear-sidecar` shows it most, 6 to 7 calls against 4. Over all 21 tasks the app server takes 11% less time per task (25.0s against 28.2s).

graff main costs 41% less per task on the app server's own reported usage ($0.0164 against $0.0278), and 43% to 69% less once the app server's unreported warm-up request is counted (see Caveats). graff reads more of its input from cache (93% against 86%); part of that gap is the same warm-up, which caches the app server's first real request without appearing in its usage.

Every arm passed all 63 runs.

## Per task

Wall time is the mean of 3 runs.

| Task | Suite | graff v0.0.302.11 | graff main | Codex app server |
| --- | --- | ---: | ---: | ---: |
| [`csv-sum`](../../graff-evals/tasks/11-csv-sum.json) | core | 16.8s | 15.2s | 22.1s |
| [`dead-code`](../../graff-evals/tasks/12-dead-code.json) | core | 8.9s | 9.0s | 18.9s |
| [`exact-reply`](../../graff-evals/tasks/01-exact-reply.json) | core | 4.4s | 4.3s | 6.4s |
| [`file-ops`](../../graff-evals/tasks/03-file-ops.json) | core | 22.4s | 21.2s | 11.8s |
| [`fix-fib`](../../graff-evals/tasks/02-fix-fib.json) | core | 20.9s | 20.5s | 21.6s |
| [`git-ops`](../../graff-evals/tasks/08-git-ops.json) | core | 24.4s | 32.7s | 17.9s |
| [`json-transform`](../../graff-evals/tasks/04-json-transform.json) | core | 20.0s | 20.8s | 20.5s |
| [`linear-issues`](../../graff-evals/tasks/24-linear-issues.json) | mcp | 33.7s | 36.7s | 27.1s |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | mcp | 42.6s | 43.7s | 31.1s |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | mcp | 43.3s | 39.5s | 31.1s |
| [`linear-quiet`](../../graff-evals/tasks/28-linear-quiet.json) | mcp | 35.5s | 33.8s | 29.6s |
| [`linear-quiet-warm`](../../graff-evals/tasks/29-linear-quiet-warm.json) | mcp | 34.0s | 33.6s | 29.1s |
| [`linear-reduce`](../../graff-evals/tasks/32-linear-reduce.json) | mcp | 38.2s | 36.9s | 34.6s |
| [`linear-reduce-warm`](../../graff-evals/tasks/33-linear-reduce-warm.json) | mcp | 39.5s | 34.5s | 36.2s |
| [`linear-sidecar`](../../graff-evals/tasks/26-linear-sidecar.json) | mcp | 49.0s | 46.8s | 27.1s |
| [`linear-split`](../../graff-evals/tasks/27-linear-split.json) | mcp | 114.6s | 65.7s | 58.0s |
| [`linear-warm`](../../graff-evals/tasks/25-linear-warm.json) | mcp | 35.0s | 28.9s | 26.2s |
| [`recall-noise`](../../graff-evals/tasks/09-recall-noise.json) | core | 7.2s | 7.4s | 10.2s |
| [`refactor-rename`](../../graff-evals/tasks/06-refactor-rename.json) | core | 24.3s | 20.7s | 26.9s |
| [`regex-count`](../../graff-evals/tasks/05-regex-count.json) | core | 18.8s | 19.1s | 14.1s |
| [`write-tests`](../../graff-evals/tasks/07-write-tests.json) | core | 22.0s | 21.6s | 23.6s |

`results.json` has every run: pass, wall time, model calls, input, cached input and output tokens, and list cost.

## Method

- **Tasks.** 11 coding tasks (`core`) and 10 tasks against a Linear-shaped MCP server (`mcp`, [`scripts/linear_fixture_mcp.py`](../../scripts/linear_fixture_mcp.py)), from [`graff-evals/tasks`](../../graff-evals/tasks). The fixture declares its two list tools read-only (`readOnlyHint`), as the hosted server it imitates does. Each task passes or fails on its own check.
- **Order.** 3 runs per task and arm, arms interleaved task by task (`run.py --interleave`), 8 runs at a time. Each arm made one unscored request first, so no arm started with a prompt cache the others had warmed.
- **Wall time.** The runner's clock around each process, start to exit.
- **Cost.** List price of the tokens each harness reports: $2 per 1M input, $0.10 per 1M cached input and $10 per 1M output ([`graff-evals/list_price.py`](../../graff-evals/list_price.py)). A ChatGPT plan is not billed per token; this makes the two harnesses comparable, not a bill.

## Caveats

- **Codex's reported usage leaves out one request.** Before a thread's first turn the app server sends a warm-up request (`generate: false`) with its instructions and tools, about 12k tokens. Its usage is not reported, so the Codex cost above is a floor. Counting it adds between about $0.001 per task (fully cached) and $0.025 (uncached).
- **Every task runs in a fresh git repository.** A session that stays in one repository sees fewer cold first requests in either harness.
- **`file-ops` has a newline in its prompt.** The scripted repl sends each line as a turn, so graff runs that task as two turns and the app server as one.
- **Small sample.** 3 runs per task, one machine, one account, one 12-minute run. A few seconds per task is within run-to-run noise.

## Reproduce

```sh
cd graff-evals
# graff-codex-repl runs {repo}/zig-out/bin/graff; --binary points it elsewhere.
# The app server needs `codex` on PATH and CODEX_HOME at a signed-in Codex home.
# Keep --output-root outside any repository, with scripts/linear_fixture_mcp.py
# copied to <parent of output-root>/scripts/ for the mcp suite.
python3 run.py --harness graff-codex-repl,codex-app-server --model gpt-6.1-sol \
  --suite core,mcp --reps 3 -j 8 --interleave --output-root /path/outside/repo/run \
  --task exact-reply --task fix-fib --task file-ops --task json-transform --task regex-count \
  --task refactor-rename --task write-tests --task git-ops --task recall-noise --task csv-sum \
  --task dead-code --task linear-issues --task linear-warm --task linear-sidecar \
  --task linear-split --task linear-quiet --task linear-quiet-warm --task linear-nohint \
  --task linear-nohint-warm --task linear-reduce --task linear-reduce-warm
```
