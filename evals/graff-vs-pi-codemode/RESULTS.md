# graff and Pi 1.0, with and without their code modes

Measured 2026-10-02 on two models: MiMo v2.6 Pro (every arm sent the same model id to the same endpoint with the same key) and gpt-6-astra on a ChatGPT plan. One machine, arms interleaved task by task, 3 runs of each task.

Pi 1.0 added `codemode`: the model writes JavaScript that calls tools as async functions in a QuickJS sandbox, and only what the script prints reaches the model. graff's code mode is `rlm`, a call-only script ([ADR 0029](../../docs/adr/0029-mcp-inside-rlm-and-return-shapes.md)). This compares both harnesses with their code modes on and off, on tasks that need more than the ids and titles graff's MCP result trimming keeps.

## Arms

| Arm | What ran |
| --- | --- |
| graff v0.0.302.16 | The published `graff-aarch64-macos` release binary as a scripted `graff repl` at the default effort (MiMo: thinking off, [ADR 0235](../../docs/adr/0235-mimo-thinks-only-at-high-effort.md); gpt-6-astra: medium reasoning), rlm on, as it ships. `graff-gateway-repl` / `graff-repl`. |
| graff, rlm off | The same binary with `GRAFF_RLM=0`: the structured-only catalog (`graff-gateway-repl-norlm`). |
| graff + ADR 0238 | v0.0.302.16 plus [ADR 0238](../../docs/adr/0238-rlm-binds-keep-the-whole-mcp-result.md): an rlm bind keeps the whole MCP result and only `print()` shows the slim view. |
| Pi 1.0 + codemode | `@earendil-works/pi-coding-agent` 1.0.0, `pi -p --mode json` through [`graff-evals/pi1_run.py`](../../graff-evals/pi1_run.py), with codemode added to the default tools (`"defaultTools": ["+codemode"]`). |
| Pi 1.0 | The same with Pi's default tools. Pi still reaches MCP tools through codemode, its default MCP exposure, and switches codemode on when an MCP server connects. |
| Pi 1.0, MCP direct | Pi's default tools with the task's MCP server at `exposure: "direct"`: MCP tools are declared as ordinary tools and codemode never starts. |

Pi ran at the same thinking setting as graff: `--thinking off` on MiMo (sent as `thinking: {"type": "disabled"}`), `--thinking medium` on gpt-6-astra. On gpt-6-astra both harnesses used a copy of one ChatGPT sign-in with its refresh token removed. Each run gets a private home directory with only the task's MCP server.

## Tasks

| Kind | Tasks | What they need |
| --- | --- | --- |
| MCP reports | `linear-nohint`, `linear-nohint-warm` | Fetch 8 issues and every issue's comments from the Linear-shaped fixture server, write a report of ids, titles, comment counts and latest authors. |
| MCP joins | `xref-issues`, `triage-rollup`, `stale-triage` | Fields the trimmed view drops (priority, estimate) or a join with local files or git history: count issue keys in `src/` with decoys, roll issues up by priority, find priority 1 and 2 issues no commit authored since a date mentions. |
| Commit digest | `commit-digest` | Count commits per top-level directory over a pinned slice of this repository's history (271 commits by author date), in one script. |
| Multi-file coding | `solo-fix-three`, `solo-census`, `solo-rename-api`, `solo-coverage`, `solo-sidecar` | The `subagents-solo` suite: per-package bugfixes, a log census over plain and gzipped files, an API rename, an endpoint-coverage merge, a parser fix with a format doc. |

Every task has a held-out check; none is graded by a model.

## MiMo v2.6 Pro

### Session 1: all 11 tasks

| | Pass | Wall per task | Model calls per task | Input tokens per task | Read from cache | Output tokens per task |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| graff v0.0.302.16 | 27/33 | 81.5s | 8.3 | 75.9k | 90% | 1,505 |
| graff, rlm off | 30/33 | 55.1s | 8.3 | 79.1k | 90% | 1,807 |
| Pi 1.0 + codemode | 31/33 | 72.0s | 10.3 | 91.1k | 90% | 2,158 |
| Pi 1.0 | 32/33 | 92.8s | 12.4 | 110.7k | 90% | 2,753 |

By kind of task (wall per task, passes, input tokens per task):

| Kind of task | graff v0.0.302.16 | graff, rlm off | Pi 1.0 + codemode | Pi 1.0 |
| --- | ---: | ---: | ---: | ---: |
| MCP reports | 36.0s (6/6, 54k in) | 27.4s (6/6, 28k in) | 43.2s (6/6, 33k in) | 66.3s (6/6, 45k in) |
| MCP joins | 87.5s (8/9, 91k in) | 48.9s (8/9, 87k in) | 47.3s (9/9, 59k in) | 48.6s (9/9, 68k in) |
| Commit digest | 128.6s (2/3, 62k in) | 41.2s (3/3, 89k in) | 56.0s (2/3, 59k in) | 92.3s (3/3, 102k in) |
| Multi-file coding | 86.6s (11/15, 78k in) | 72.7s (13/15, 93k in) | 101.5s (14/15, 140k in) | 130.1s (14/15, 164k in) |

graff was fastest with rlm off (55.1s against 81.5s with it on). In 17 runs without an MCP server MiMo never called Pi's codemode, so Pi's two arms differ on those tasks only by noise and by codemode's tool description; on the MCP tasks both reach MCP through codemode.

| Task | Kind | graff v0.0.302.16 | graff, rlm off | Pi 1.0 + codemode | Pi 1.0 |
| --- | --- | ---: | ---: | ---: | ---: |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | MCP reports | 47.9s | 22.1s | 36.2s | 76.8s |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | MCP reports | 24.1s | 32.7s | 50.2s | 55.7s |
| [`xref-issues`](../../graff-evals/tasks/91-xref-issues.json) | MCP joins | 30.5s | 27.0s (2/3) | 51.2s | 42.7s |
| [`triage-rollup`](../../graff-evals/tasks/92-triage-rollup.json) | MCP joins | 171.9s (2/3) | 66.0s | 38.6s | 34.5s |
| [`stale-triage`](../../graff-evals/tasks/93-stale-triage.json) | MCP joins | 60.1s | 53.8s | 52.0s | 68.5s |
| [`commit-digest`](../../graff-evals/tasks/90-commit-digest.json) | Commit digest | 128.6s (2/3) | 41.2s | 56.0s (2/3) | 92.3s |
| [`solo-fix-three`](../../graff-evals/tasks/67-solo-fix-three.json) | Multi-file coding | 76.0s | 51.5s | 45.5s | 79.5s |
| [`solo-census`](../../graff-evals/tasks/68-solo-census.json) | Multi-file coding | 54.2s | 71.6s | 91.4s | 102.5s |
| [`solo-rename-api`](../../graff-evals/tasks/69-solo-rename-api.json) | Multi-file coding | 63.1s | 58.4s | 47.7s | 36.7s |
| [`solo-coverage`](../../graff-evals/tasks/70-solo-coverage.json) | Multi-file coding | 29.6s (0/3) | 44.0s (1/3) | 26.6s | 48.9s |
| [`solo-sidecar`](../../graff-evals/tasks/71-solo-sidecar.json) | Multi-file coding | 210.0s (2/3) | 138.2s | 296.1s (2/3) | 383.1s (2/3) |

### Session 2: ADR 0238 on the five MCP tasks

| | Pass | Wall per task | Model calls per task | Input tokens per task | Read from cache | Output tokens per task |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| graff + ADR 0238 | 14/15 | 31.0s | 8.3 | 72.7k | 92% | 1,012 |
| graff v0.0.302.16 | 13/15 | 37.1s | 8.6 | 82.5k | 92% | 1,128 |
| graff, rlm off | 15/15 | 38.3s | 6.7 | 69.9k | 89% | 1,032 |
| Pi 1.0 + codemode | 15/15 | 39.3s | 9.1 | 45.5k | 84% | 1,412 |

| Kind of task | graff + ADR 0238 | graff v0.0.302.16 | graff, rlm off | Pi 1.0 + codemode |
| --- | ---: | ---: | ---: | ---: |
| MCP reports | 26.2s (5/6, 54k in) | 32.9s (5/6, 55k in) | 18.3s (6/6, 28k in) | 37.4s (6/6, 44k in) |
| MCP joins | 34.1s (9/9, 85k in) | 39.9s (8/9, 101k in) | 51.7s (9/9, 98k in) | 40.6s (9/9, 46k in) |

| Task | Kind | graff + ADR 0238 | graff v0.0.302.16 | graff, rlm off | Pi 1.0 + codemode |
| --- | --- | ---: | ---: | ---: | ---: |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | MCP reports | 37.0s | 42.2s | 17.2s | 27.9s |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | MCP reports | 15.4s (2/3) | 23.7s (2/3) | 19.3s | 46.9s |
| [`xref-issues`](../../graff-evals/tasks/91-xref-issues.json) | MCP joins | 15.6s | 32.2s | 31.4s | 39.2s |
| [`triage-rollup`](../../graff-evals/tasks/92-triage-rollup.json) | MCP joins | 40.0s | 56.0s | 62.7s | 40.8s |
| [`stale-triage`](../../graff-evals/tasks/93-stale-triage.json) | MCP joins | 46.8s | 31.5s (2/3) | 60.9s | 42.0s |

### Session 3: Pi with and without codemode on the five MCP tasks

| | Pass | Wall per task | Model calls per task | Input tokens per task | Read from cache | Output tokens per task |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Pi 1.0 + codemode | 14/15 | 34.3s | 8.7 | 47.6k | 84% | 1,318 |
| Pi 1.0 | 15/15 | 37.8s | 8.8 | 44.8k | 84% | 1,399 |
| Pi 1.0, MCP direct | 15/15 | 30.5s | 6.9 | 66.9k | 79% | 1,229 |

| Kind of task | Pi 1.0 + codemode | Pi 1.0 | Pi 1.0, MCP direct |
| --- | ---: | ---: | ---: |
| MCP reports | 33.9s (6/6, 35k in) | 38.3s (6/6, 41k in) | 31.6s (6/6, 77k in) |
| MCP joins | 34.5s (8/9, 56k in) | 37.4s (9/9, 47k in) | 29.8s (9/9, 60k in) |

Without codemode Pi was quicker on both kinds of MCP task; codemode read about half the input tokens on the report tasks.

## gpt-6-astra

### Session 1: all 11 tasks

| | Pass | Wall per task | Model calls per task | Input tokens per task | Read from cache | Output tokens per task |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| graff v0.0.302.16 | 33/33 | 54.1s | 4.5 | 49.4k | 89% | 788 |
| graff, rlm off | 33/33 | 57.3s | 4.6 | 52.2k | 89% | 927 |
| graff + ADR 0238 | 33/33 | 48.3s | 3.8 | 44.0k | 89% | 835 |
| Pi 1.0 + codemode | 33/33 | 41.7s | 4.8 | 20.9k | 54% | 647 |
| Pi 1.0 | 33/33 | 48.1s | 5.2 | 21.9k | 57% | 704 |

By kind of task (wall per task, passes, input tokens per task):

| Kind of task | graff v0.0.302.16 | graff, rlm off | graff + ADR 0238 | Pi 1.0 + codemode | Pi 1.0 |
| --- | ---: | ---: | ---: | ---: | ---: |
| MCP reports | 31.5s (6/6, 39k in) | 38.5s (6/6, 45k in) | 31.4s (6/6, 41k in) | 30.5s (6/6, 26k in) | 30.9s (6/6, 26k in) |
| MCP joins | 51.4s (9/9, 83k in) | 55.8s (9/9, 78k in) | 37.7s (9/9, 46k in) | 34.8s (9/9, 34k in) | 36.7s (9/9, 38k in) |
| Commit digest | 42.2s (3/3, 35k in) | 48.4s (3/3, 45k in) | 34.7s (3/3, 30k in) | 32.7s (3/3, 10k in) | 29.8s (3/3, 9k in) |
| Multi-file coding | 67.2s (15/15, 37k in) | 67.5s (15/15, 41k in) | 64.2s (15/15, 47k in) | 52.1s (15/15, 13k in) | 65.3s (15/15, 13k in) |

Every arm passed every run. With codemode in its default tools Pi used it in 8 of 12 runs without an MCP server (reading files and running commands from a script), and was fastest on the multi-file tasks. rlm helped graff a little (54.1s against 57.3s); astra's rlm scripts were never refused. ADR 0238 took graff from 54.1s to 48.3s per task and from 51.4s to 37.7s on the join tasks; no run paged a stored result with `read_tool_result`, against 6 of 33 for v0.0.302.16.

| Task | Kind | graff v0.0.302.16 | graff, rlm off | graff + ADR 0238 | Pi 1.0 + codemode | Pi 1.0 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | MCP reports | 34.3s | 38.5s | 31.4s | 30.8s | 28.9s |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | MCP reports | 28.8s | 38.5s | 31.4s | 30.3s | 32.9s |
| [`xref-issues`](../../graff-evals/tasks/91-xref-issues.json) | MCP joins | 37.7s | 38.3s | 38.1s | 36.9s | 43.2s |
| [`triage-rollup`](../../graff-evals/tasks/92-triage-rollup.json) | MCP joins | 60.1s | 76.3s | 36.3s | 32.5s | 31.9s |
| [`stale-triage`](../../graff-evals/tasks/93-stale-triage.json) | MCP joins | 56.5s | 52.9s | 38.8s | 34.9s | 35.1s |
| [`commit-digest`](../../graff-evals/tasks/90-commit-digest.json) | Commit digest | 42.2s | 48.4s | 34.7s | 32.7s | 29.8s |
| [`solo-fix-three`](../../graff-evals/tasks/67-solo-fix-three.json) | Multi-file coding | 53.0s | 53.1s | 52.5s | 50.6s | 93.6s |
| [`solo-census`](../../graff-evals/tasks/68-solo-census.json) | Multi-file coding | 36.4s | 42.3s | 40.1s | 25.1s | 25.5s |
| [`solo-rename-api`](../../graff-evals/tasks/69-solo-rename-api.json) | Multi-file coding | 114.8s | 105.3s | 92.7s | 63.6s | 84.5s |
| [`solo-coverage`](../../graff-evals/tasks/70-solo-coverage.json) | Multi-file coding | 43.3s | 49.9s | 47.9s | 37.8s | 39.4s |
| [`solo-sidecar`](../../graff-evals/tasks/71-solo-sidecar.json) | Multi-file coding | 88.5s | 86.8s | 87.8s | 83.2s | 83.8s |

### Session 2: Pi with and without codemode on the five MCP tasks

| | Pass | Wall per task | Model calls per task | Input tokens per task | Read from cache | Output tokens per task |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Pi 1.0 + codemode | 15/15 | 41.2s | 5.3 | 29.9k | 50% | 388 |
| Pi 1.0 | 15/15 | 35.6s | 5.7 | 33.7k | 55% | 402 |
| Pi 1.0, MCP direct | 15/15 | 40.6s | 5.6 | 41.7k | 63% | 477 |

| Kind of task | Pi 1.0 + codemode | Pi 1.0 | Pi 1.0, MCP direct |
| --- | ---: | ---: | ---: |
| MCP reports | 32.3s (6/6, 26k in) | 34.2s (6/6, 29k in) | 55.8s (6/6, 63k in) |
| MCP joins | 47.1s (9/9, 33k in) | 36.5s (9/9, 37k in) | 30.5s (9/9, 27k in) |

On the report tasks codemode was quicker and read less than half the input tokens; on the join tasks the direct arm was quicker and read fewer tokens.

## Where the time went

- Pi reached MCP through codemode in every MCP run on both models and fetched and transformed data in one script in 28 of 30 runs on MiMo and 18 of 30 on gpt-6-astra. MCP tools are not listed in codemode's description, so a run spent about two calls on `searchTools()` / `describeTool()` before its first fetch.
- graff v0.0.302.16 bound the trimmed cut inside rlm (ids and titles; comment lists as a count and the latest author), so tasks that needed other fields left the script and paged the stored result with `read_tool_result`, whose slices end in a `[a..b of N bytes]` marker that broke the JSON when joined. ADR 0238 binds the whole result.
- MiMo used rlm in 13 of 33 runs (session 1) and hit a refusal in 5 (Python-shaped scripts: loops, comprehensions, multi-argument calls). gpt-6-astra's rlm was never refused.
- On `solo-coverage` graff's model wrote `coverage.json` by hand in all six MiMo runs and five failed (unsorted or a dropped endpoint); Pi computed it with a script in all six and passed.
- graff never names the working directory in its prompt; MiMo sometimes opens with `cd` into an invented path such as `/Users/dev/workspace-…` (6 graff runs in session 1). gpt-6-astra never did.
- graff's first request is about 10,500 input tokens on gpt-6-astra (about 6,200 on MiMo), Pi's about 1,600 (about 2,000 on MiMo), so graff reads roughly twice Pi's input per task; graff's cache hit rate is higher (89% against 54-57% on astra).

## Notes

- Three runs per task is a small sample, and an endpoint's latency swings a lot over a day: compare arms only within a session.
- Wall time is the runner's clock around each process. Model calls and tokens are each harness's own usage report; input includes cached tokens.
- `commit-digest` fetches a pinned commit of this repository from GitHub in its setup; the counts come from that history.
