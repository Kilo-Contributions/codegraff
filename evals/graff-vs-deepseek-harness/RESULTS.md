# graff vs deepseek-harness on DeepSeek V4 Pro

Measured 2026-10-02. Both harnesses ran DeepSeek V4 Pro (`deepseek-v4-pro`) on DeepSeek's own API with the same key, side by side on one machine, interleaved task by task.

v0.0.302.15 changed what graff's default effort sends to DeepSeek; [DEFAULT-EFFORT.md](DEFAULT-EFFORT.md) measures it against this page's build.

| Arm | What ran |
| --- | --- |
| graff | The v0.0.302.14 code (#1445, #1451-#1454) as a scripted `graff repl` with `--model deepseek/deepseek-v4-pro`, at graff's default effort. |
| deepseek-harness | `@deepseek-ai/dsh` 0.2.0-rc.2: `dsh --profile headless --json`, through [`graff-evals/dsh_run.py`](../../graff-evals/dsh_run.py). dsh has no `--model` flag, so a patch layer pins the model; dsh does not read `.mcp.json`, so the same layer adds the task's MCP servers as `dsh-mcp-client` entries. It runs at its own defaults. |

## Results

The 11 coding tasks and 10 MCP tasks, mean per task over 2 runs of each:

| | Pass | Wall per task | Input read from cache | Output tokens per task | Model calls per task |
| --- | ---: | ---: | ---: | ---: | ---: |
| graff | 42/42 | 22.6s | 94% | 2,635 | 4.1 |
| deepseek-harness | 42/42 | 27.7s | 87% | 2,537 | 6.3 |

By suite:

| Suite | graff | deepseek-harness |
| --- | ---: | ---: |
| core (11 coding tasks), wall | 6.4s | 7.4s |
| core (11 coding tasks), pass | 22/22 | 22/22 |
| core (11 coding tasks), model calls | 3.3 | 3.5 |
| mcp (10 MCP tasks), wall | 40.4s | 50.2s |
| mcp (10 MCP tasks), pass | 20/20 | 20/20 |
| mcp (10 MCP tasks), model calls | 5.0 | 9.2 |

graff finishes the 21 tasks in 19% less time (22.6s against 27.7s per task). Most of the gap is the MCP tasks (40.4s against 50.2s), where graff makes about half the model calls (5.0 against 9.2): it slims large list results and often fetches, reduces and writes the report in one `rlm` script. On the coding tasks graff is also faster (6.4s against 7.4s) and reads more of its prompt from cache.

## Sub-agents

The `subagents` suite (five tasks that ask for parallel sub-agents) and its `subagents-solo` counterfactual (the same work without delegation), 2 runs each:

| Suite | graff | deepseek-harness |
| --- | ---: | ---: |
| subagents, wall | 63.7s | 70.4s |
| subagents, pass | 9/10 | 8/10 |
| subagents-solo, wall | 27.7s | 38.1s |
| subagents-solo, pass | 9/10 | 9/10 |

deepseek-harness's sub-agents run in its own process, and its run events report the parent's model calls only, so token and call counts are not compared for these suites.

## Per task

Wall time is the mean of 2 runs; a task that failed in a run is marked with its pass count.

| Task | Suite | graff | deepseek-harness |
| --- | --- | ---: | ---: |
| [`csv-sum`](../../graff-evals/tasks/11-csv-sum.json) | core | 4.6s | 6.1s |
| [`dead-code`](../../graff-evals/tasks/12-dead-code.json) | core | 3.6s | 9.3s |
| [`exact-reply`](../../graff-evals/tasks/01-exact-reply.json) | core | 1.5s | 2.3s |
| [`file-ops`](../../graff-evals/tasks/03-file-ops.json) | core | 5.2s | 4.8s |
| [`fix-fib`](../../graff-evals/tasks/02-fix-fib.json) | core | 8.1s | 9.8s |
| [`git-ops`](../../graff-evals/tasks/08-git-ops.json) | core | 10.3s | 8.5s |
| [`json-transform`](../../graff-evals/tasks/04-json-transform.json) | core | 4.8s | 5.6s |
| [`recall-noise`](../../graff-evals/tasks/09-recall-noise.json) | core | 3.0s | 3.1s |
| [`refactor-rename`](../../graff-evals/tasks/06-refactor-rename.json) | core | 8.2s | 12.9s |
| [`regex-count`](../../graff-evals/tasks/05-regex-count.json) | core | 6.5s | 8.0s |
| [`write-tests`](../../graff-evals/tasks/07-write-tests.json) | core | 14.3s | 10.8s |
| [`linear-issues`](../../graff-evals/tasks/24-linear-issues.json) | mcp | 43.5s | 41.1s |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | mcp | 29.2s | 29.0s |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | mcp | 22.3s | 27.6s |
| [`linear-quiet`](../../graff-evals/tasks/28-linear-quiet.json) | mcp | 81.4s | 34.6s |
| [`linear-quiet-warm`](../../graff-evals/tasks/29-linear-quiet-warm.json) | mcp | 56.1s | 98.4s |
| [`linear-reduce`](../../graff-evals/tasks/32-linear-reduce.json) | mcp | 37.1s | 32.9s |
| [`linear-reduce-warm`](../../graff-evals/tasks/33-linear-reduce-warm.json) | mcp | 18.7s | 43.7s |
| [`linear-sidecar`](../../graff-evals/tasks/26-linear-sidecar.json) | mcp | 49.1s | 36.6s |
| [`linear-split`](../../graff-evals/tasks/27-linear-split.json) | mcp | 34.5s | 86.6s |
| [`linear-warm`](../../graff-evals/tasks/25-linear-warm.json) | mcp | 31.6s | 71.0s |
| [`sa-census`](../../graff-evals/tasks/63-sa-census.json) | subagents | 79.2s | 62.4s |
| [`sa-coverage`](../../graff-evals/tasks/65-sa-coverage.json) | subagents | 29.1s (1/2) | 37.8s (0/2) |
| [`sa-fix-three`](../../graff-evals/tasks/62-sa-fix-three.json) | subagents | 45.2s | 54.4s |
| [`sa-rename-api`](../../graff-evals/tasks/64-sa-rename-api.json) | subagents | 77.2s | 69.8s |
| [`sa-sidecar`](../../graff-evals/tasks/66-sa-sidecar.json) | subagents | 87.8s | 127.6s |
| [`solo-census`](../../graff-evals/tasks/68-solo-census.json) | subagents-solo | 20.9s | 34.0s |
| [`solo-coverage`](../../graff-evals/tasks/70-solo-coverage.json) | subagents-solo | 18.1s (1/2) | 21.5s (1/2) |
| [`solo-fix-three`](../../graff-evals/tasks/67-solo-fix-three.json) | subagents-solo | 28.5s | 37.0s |
| [`solo-rename-api`](../../graff-evals/tasks/69-solo-rename-api.json) | subagents-solo | 34.5s | 40.5s |
| [`solo-sidecar`](../../graff-evals/tasks/71-solo-sidecar.json) | subagents-solo | 36.3s | 57.7s |

## Reproduce

```sh
cd graff-evals
export DEEPSEEK_API_KEY=...
python3 run.py --harness graff-deepseek,deepseek-harness --model deepseek-v4-pro --suite core,mcp --reps 2 --interleave
python3 run.py --harness graff-deepseek,deepseek-harness --model deepseek-v4-pro --suite subagents,subagents-solo --reps 2 --interleave
```

