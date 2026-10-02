# DeepSeek V4 Pro at graff's default effort

Measured 2026-10-02. Every arm ran DeepSeek V4 Pro (`deepseek-v4-pro`) on DeepSeek's own API with the same key, side by side on one machine, interleaved task by task.

v0.0.302.15 changes what graff's default effort sends to DeepSeek ([ADR 0237](../../docs/adr/0237-deepseek-thinks-at-its-low-level-by-default.md)): `reasoning_effort: low` with thinking enabled, where v0.0.302.14 sent `medium`. `/effort low` still turns thinking off, and `high` and above are unchanged.

| Arm | What ran |
| --- | --- |
| v0.0.302.14 | The v0.0.302.14 code as a scripted `graff repl` with `--model deepseek/deepseek-v4-pro`, at the default effort: `reasoning_effort: medium`, thinking on. |
| v0.0.302.15 | This release's code, run the same way: `reasoning_effort: low`, thinking on. |
| Low, thinking on | The v0.0.302.14 code with an experiment switch that sends what v0.0.302.15 sends. The rounds that chose the default ran it. |
| Thinking off | The v0.0.302.14 code with an experiment switch that sends `reasoning_effort: low` with thinking disabled, as `/effort low` does. |
| deepseek-harness | `@deepseek-ai/dsh` 0.2.0-rc.2 through [`graff-evals/dsh_run.py`](../../graff-evals/dsh_run.py), at its own defaults, as in [RESULTS.md](RESULTS.md). |

## v0.0.302.14 against v0.0.302.15

The 11 coding tasks and 10 MCP tasks, mean per task over 2 runs of each:

| | Pass | Wall per task | Coding tasks | MCP tasks | Output tokens per task |
| --- | ---: | ---: | ---: | ---: | ---: |
| v0.0.302.14 | 42/42 | 21.6s | 6.8s | 37.8s | 1,941 |
| v0.0.302.15 | 41/42 | 15.9s | 6.2s | 26.5s | 1,235 |

This release took 26% less time over the 21 tasks (15.9s against 21.6s per task) and wrote 36% fewer output tokens. Most of the gap is the MCP tasks (26.5s against 37.8s), where the first request of a turn reasoned for about 3,200 characters on average against 7,800. It missed one run: on `regex-count` it ran `grep -c '^ERROR'`, which also counts the `ERRORS_TOTAL` line the prompt rules out, and wrote 5 instead of 4. One `linear-sidecar` run took 101s over 17 model calls, against 26s for the other.

The first round below measured the same request at 11.9s against 24.2s per task; v0.0.302.14 reasoned longer in that round, about 13,200 characters on the first MCP request.

The `subagents` suite (five tasks that ask for parallel sub-agents) and its `subagents-solo` counterfactual (the same work without delegation), 2 runs each:

| | Pass | Wall per task | subagents | subagents-solo | Output tokens per task |
| --- | ---: | ---: | ---: | ---: | ---: |
| v0.0.302.14 | 20/20 | 61.9s | 85.7s | 38.0s | 7,964 |
| v0.0.302.15 | 20/20 | 37.7s | 52.9s | 22.6s | 4,972 |

Every sub-agent task got faster, from 17% on `sa-fix-three` to 58% on `solo-sidecar`.

## How the default was chosen

The first round ran four arms on the coding and MCP tasks, 2 runs each:

| | Pass | Wall per task | Coding tasks | MCP tasks | Output tokens per task |
| --- | ---: | ---: | ---: | ---: | ---: |
| v0.0.302.14 | 42/42 | 24.2s | 5.3s | 45.0s | 2,578 |
| Low, thinking on | 42/42 | 11.9s | 5.2s | 19.3s | 1,104 |
| Thinking off | 41/42 | 7.6s | 4.7s | 10.9s | 560 |
| deepseek-harness | 42/42 | 25.5s | 7.0s | 45.8s | 2,501 |

The next ran three on the sub-agent suites:

| | Pass | Wall per task | subagents | subagents-solo | Output tokens per task |
| --- | ---: | ---: | ---: | ---: | ---: |
| v0.0.302.14 | 20/20 | 54.6s | 77.8s | 31.3s | 7,748 |
| Low, thinking on | 18/20 | 35.7s | 45.9s | 25.5s | 5,009 |
| Thinking off | 15/20 | 27.6s | 33.8s | 21.4s | 3,667 |

Thinking off was the fastest and missed the most: one `regex-count` run, `sa-census` twice and the coverage tasks three times. Low with thinking on missed one `sa-census` run, where a child counted each file correctly and then added the counts up wrong, and one `solo-coverage` run, which misread a route's method. The v0.0.302.14 code missed one run of each coverage task in the earlier comparison ([RESULTS.md](RESULTS.md#sub-agents)). So the default keeps thinking on at `low`, and thinking off stays behind `/effort low`.

## Per task

v0.0.302.14 against v0.0.302.15. Wall time is the mean of 2 runs; a task that failed in a run is marked with its pass count.

| Task | Suite | v0.0.302.14 | v0.0.302.15 |
| --- | --- | ---: | ---: |
| [`csv-sum`](../../graff-evals/tasks/11-csv-sum.json) | core | 5.1s | 3.8s |
| [`dead-code`](../../graff-evals/tasks/12-dead-code.json) | core | 2.8s | 3.0s |
| [`exact-reply`](../../graff-evals/tasks/01-exact-reply.json) | core | 2.6s | 2.8s |
| [`file-ops`](../../graff-evals/tasks/03-file-ops.json) | core | 7.9s | 11.8s |
| [`fix-fib`](../../graff-evals/tasks/02-fix-fib.json) | core | 12.6s | 13.3s |
| [`git-ops`](../../graff-evals/tasks/08-git-ops.json) | core | 8.2s | 6.2s |
| [`json-transform`](../../graff-evals/tasks/04-json-transform.json) | core | 5.2s | 5.5s |
| [`recall-noise`](../../graff-evals/tasks/09-recall-noise.json) | core | 2.6s | 2.5s |
| [`refactor-rename`](../../graff-evals/tasks/06-refactor-rename.json) | core | 7.7s | 6.9s |
| [`regex-count`](../../graff-evals/tasks/05-regex-count.json) | core | 8.0s | 4.2s (1/2) |
| [`write-tests`](../../graff-evals/tasks/07-write-tests.json) | core | 12.4s | 8.7s |
| [`linear-issues`](../../graff-evals/tasks/24-linear-issues.json) | mcp | 26.9s | 16.4s |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | mcp | 17.3s | 20.3s |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | mcp | 40.9s | 23.8s |
| [`linear-quiet`](../../graff-evals/tasks/28-linear-quiet.json) | mcp | 50.4s | 8.9s |
| [`linear-quiet-warm`](../../graff-evals/tasks/29-linear-quiet-warm.json) | mcp | 47.5s | 24.5s |
| [`linear-reduce`](../../graff-evals/tasks/32-linear-reduce.json) | mcp | 30.1s | 18.7s |
| [`linear-reduce-warm`](../../graff-evals/tasks/33-linear-reduce-warm.json) | mcp | 35.8s | 20.0s |
| [`linear-sidecar`](../../graff-evals/tasks/26-linear-sidecar.json) | mcp | 42.0s | 63.4s |
| [`linear-split`](../../graff-evals/tasks/27-linear-split.json) | mcp | 45.5s | 48.0s |
| [`linear-warm`](../../graff-evals/tasks/25-linear-warm.json) | mcp | 42.1s | 21.2s |
| [`sa-census`](../../graff-evals/tasks/63-sa-census.json) | subagents | 81.0s | 41.2s |
| [`sa-coverage`](../../graff-evals/tasks/65-sa-coverage.json) | subagents | 56.5s | 24.3s |
| [`sa-fix-three`](../../graff-evals/tasks/62-sa-fix-three.json) | subagents | 51.4s | 42.8s |
| [`sa-rename-api`](../../graff-evals/tasks/64-sa-rename-api.json) | subagents | 86.0s | 63.5s |
| [`sa-sidecar`](../../graff-evals/tasks/66-sa-sidecar.json) | subagents | 153.8s | 92.8s |
| [`solo-census`](../../graff-evals/tasks/68-solo-census.json) | subagents-solo | 23.9s | 16.7s |
| [`solo-coverage`](../../graff-evals/tasks/70-solo-coverage.json) | subagents-solo | 18.9s | 15.9s |
| [`solo-fix-three`](../../graff-evals/tasks/67-solo-fix-three.json) | subagents-solo | 25.5s | 19.7s |
| [`solo-rename-api`](../../graff-evals/tasks/69-solo-rename-api.json) | subagents-solo | 40.8s | 26.5s |
| [`solo-sidecar`](../../graff-evals/tasks/71-solo-sidecar.json) | subagents-solo | 80.9s | 34.1s |

## Reproduce

`graff-evals/run.py` with `--model deepseek-v4-pro`, one graff arm per binary, `--suite core,mcp` and then `--suite subagents,subagents-solo`, `--reps 2 --interleave`. A graff arm for another build is a copy of the `graff-deepseek` arm whose command points at that build's binary. Set `DEEPSEEK_API_KEY` first.
