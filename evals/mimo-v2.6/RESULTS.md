# MiMo v2.6: v0.0.302.13 against v0.0.302.14 and OpenCode 2

Measured 2026-10-02. Every arm sent the same model id to the same endpoint with the same key, on one machine, interleaved task by task, 2 runs of each of the 21 tasks.

v0.0.302.14 changes what graff's default effort means on MiMo ([ADR 0235](../../docs/adr/0235-mimo-thinks-only-at-high-effort.md)): thinking is Off below `high`, so MiMo acts without first reasoning at length. `/effort high` turns thinking back on.

## MiMo v2.6 Pro

| Arm | What ran |
| --- | --- |
| v0.0.302.13 | The published `graff-aarch64-macos` release binary as a scripted `graff repl`, at the default effort (MiMo thinking on). |
| v0.0.302.14 | This release's build as a scripted `graff repl`, at the default effort (MiMo thinking off). |
| OpenCode 2 | `@opencode/cli` 2.0.21: `opencode run --standalone --auto --format json`, through [`graff-evals/opencode2_run.py`](../../graff-evals/opencode2_run.py), at its own defaults. |

| | Pass | Wall per task | Input read from cache | Output tokens per task | Model calls per task |
| --- | ---: | ---: | ---: | ---: | ---: |
| v0.0.302.13 | 42/42 | 53.1s | 86% | 2,353 | 4.3 |
| v0.0.302.14 | 39/42 | 18.1s | 93% | 544 | 4.6 |
| OpenCode 2 | 42/42 | 30.9s | 87% | 1,004 | 4.6 |

By suite:

| Suite | v0.0.302.13 | v0.0.302.14 | OpenCode 2 |
| --- | ---: | ---: | ---: |
| core (11 coding tasks), wall | 15.8s | 11.5s | 17.4s |
| core (11 coding tasks), pass | 22/22 | 21/22 | 22/22 |
| mcp (10 MCP tasks), wall | 94.2s | 25.5s | 45.7s |
| mcp (10 MCP tasks), pass | 20/20 | 18/20 | 20/20 |

v0.0.302.14 finishes the 21 tasks 2.9x as fast as v0.0.302.13 (18.1s against 53.1s per task) and in 41% less time than OpenCode 2 (30.9s). The MCP tasks show it most: 25.5s against 94.2s for v0.0.302.13 and 45.7s for OpenCode 2. v0.0.302.13 wrote 2,353 output tokens per task, nearly all of it thinking; v0.0.302.14 writes 544.

Without thinking, MiMo missed 3 of 42 runs: one reply on `file-ops` was a JSON fragment instead of a tool call, and on `linear-quiet-warm` it twice reported the issues' display numbers instead of their ids. v0.0.302.13 and OpenCode 2 passed every run. For work that needs careful reading, `/effort high` turns MiMo's thinking back on.

## MiMo v2.6 Flash

Measured the same way an hour earlier. The thinking-on arm is the v0.0.302.14 code without #1453 and #1454, so it thinks at the default effort.

| | Pass | Wall per task | Output tokens per task | Model calls per task |
| --- | ---: | ---: | ---: | ---: |
| graff, thinking on | 42/42 | 35.1s | 1,473 | 5.5 |
| v0.0.302.14 (thinking off) | 40/42 | 16.7s | 551 | 5.4 |
| OpenCode 2 | 42/42 | 26.6s | 1,025 | 5.2 |

With thinking off, Flash finishes the tasks 2.1x as fast (16.7s against 35.1s) and in 37% less time than OpenCode 2 (26.6s). Its two misses were the same task, `linear-nohint-warm`, where it reported the issues' display numbers instead of their ids.

## Per task (Pro)

Wall time is the mean of 2 runs; a task that failed in a run is marked with its pass count.

| Task | Suite | v0.0.302.13 | v0.0.302.14 | OpenCode 2 |
| --- | --- | ---: | ---: | ---: |
| [`csv-sum`](../../graff-evals/tasks/11-csv-sum.json) | core | 15.2s | 13.6s | 22.6s |
| [`dead-code`](../../graff-evals/tasks/12-dead-code.json) | core | 6.5s | 5.9s | 10.2s |
| [`exact-reply`](../../graff-evals/tasks/01-exact-reply.json) | core | 5.9s | 5.5s | 6.2s |
| [`file-ops`](../../graff-evals/tasks/03-file-ops.json) | core | 11.3s | 3.7s (1/2) | 18.4s |
| [`fix-fib`](../../graff-evals/tasks/02-fix-fib.json) | core | 17.7s | 14.0s | 22.6s |
| [`git-ops`](../../graff-evals/tasks/08-git-ops.json) | core | 53.6s | 22.3s | 26.4s |
| [`json-transform`](../../graff-evals/tasks/04-json-transform.json) | core | 10.7s | 10.2s | 13.2s |
| [`recall-noise`](../../graff-evals/tasks/09-recall-noise.json) | core | 7.2s | 11.8s | 13.5s |
| [`refactor-rename`](../../graff-evals/tasks/06-refactor-rename.json) | core | 16.3s | 16.9s | 15.6s |
| [`regex-count`](../../graff-evals/tasks/05-regex-count.json) | core | 16.3s | 12.0s | 21.2s |
| [`write-tests`](../../graff-evals/tasks/07-write-tests.json) | core | 13.7s | 10.4s | 21.5s |
| [`linear-issues`](../../graff-evals/tasks/24-linear-issues.json) | mcp | 122.3s | 16.5s | 37.8s |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | mcp | 55.2s | 17.1s | 40.3s |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | mcp | 46.9s | 14.2s | 39.7s |
| [`linear-quiet`](../../graff-evals/tasks/28-linear-quiet.json) | mcp | 88.7s | 19.2s | 35.5s |
| [`linear-quiet-warm`](../../graff-evals/tasks/29-linear-quiet-warm.json) | mcp | 79.1s | 25.7s (0/2) | 52.0s |
| [`linear-reduce`](../../graff-evals/tasks/32-linear-reduce.json) | mcp | 100.5s | 21.4s | 43.1s |
| [`linear-reduce-warm`](../../graff-evals/tasks/33-linear-reduce-warm.json) | mcp | 149.8s | 22.9s | 44.4s |
| [`linear-sidecar`](../../graff-evals/tasks/26-linear-sidecar.json) | mcp | 154.6s | 45.7s | 54.2s |
| [`linear-split`](../../graff-evals/tasks/27-linear-split.json) | mcp | 87.9s | 53.4s | 69.8s |
| [`linear-warm`](../../graff-evals/tasks/25-linear-warm.json) | mcp | 56.7s | 18.6s | 39.8s |

## Reproduce

`graff-evals/run.py` with `--model mimo-v2.6-pro` (or `mimo-v2.6-flash`), one graff arm per binary plus `opencode2`, `--suite core,mcp --reps 2 --interleave`. A graff arm for a previous release is a copy of a scripted-repl arm whose command points at that release's binary.
