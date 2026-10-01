# graff vs the Codex app server on gpt-6-astra, with sub-agents

Measured 2026-10-01. The same model (`gpt-6-astra`), ChatGPT account and machine ran the same tasks in each harness, interleaved.

| Arm | What ran |
| --- | --- |
| graff | This PR's build: [ADR 0230](../../docs/adr/0230-mcp-connects-in-the-background.md) and [ADR 0232](../../docs/adr/0232-sub-agents-at-parity-with-the-codex-route.md) on top of v0.0.302.13, as a scripted `graff repl` over the Codex Responses WebSocket. |
| Codex app server | `codex app-server` from codex-cli 0.159.0, through [`graff-evals/codex_app_server.py`](../../graff-evals/codex_app_server.py). |

Both run at the model catalog's defaults: `medium` effort, `low` verbosity. graff delegates with its `subagent` tool; the app server with its multi-agent tools, which run at most three children at a time.

## Results

Mean per task:

| Suite | Runs | Pass (graff / Codex) | Wall per task | List cost per task | Model calls per task |
| --- | ---: | ---: | ---: | ---: | ---: |
| core (11 coding tasks) | 2 | 22/22 / 22/22 | **15.2s** / 18.9s | **$0.077** / $0.091 | 2.9 / 3.2 |
| mcp (10 MCP tasks) | 2 | 20/20 / 20/20 | **27.2s** / 38.7s | **$0.117** / $0.436 | 3.2 / 6.0 |
| subagents (5 delegation tasks) | 3 | 15/15 / 15/15 | **71.0s** / 86.1s | **$0.427** / $1.586 | 16.3 / 24.4 |
| subagents-solo (the same 5, no delegation) | 2 | 10/10 / 10/10 | **47.9s** / 50.8s | **$0.144** / $0.192 | 4.1 / 4.0 |

graff is faster on every suite: 20% on the coding tasks, 30% on the MCP tasks, 18% when the tasks ask for sub-agents, and 6% when they do not. It costs 16%, 73%, 73% and 25% less, on the app server's own reported usage. Every arm passed every run.

The `subagents` suite is new ([graff-evals/README.md](../../graff-evals/README.md)): three packages fixed in parallel, a census of four services' logs, an API rename across three packages, a coverage merge of two inventories, and a docs sidecar beside a fix, each in a git repository with a held-out check. `subagents-solo` asks for the same work without asking for sub-agents.

## Where sub-agent time goes

Means over the `subagents` runs, from [`graff-evals/subagent_split.py`](../../graff-evals/subagent_split.py):

| | graff | Codex app server |
| --- | ---: | ---: |
| first child started | 10.3s | 22.3s |
| first to last spawn | 10.6s | 50.8s |
| first child start to last child finish | 47.1s | 48.6s |
| slowest child | 39.9s | 40.9s |
| last child finish to the end of the run | 13.2s | 12.0s |
| parent model calls | 6.7 | 13.2 |
| child model calls, all children | 9.6 | 11.2 |

The children themselves take about as long in both. graff starts them sooner and closer together: the app server spawns one child per model call and holds a fourth until a slot frees. graff's parent makes half as many calls; one `agent_output` call with `ids` collects every report.

## Did the children pay for themselves?

Not at this size, in either harness. Asked to delegate, graff took 23.1s (48%) longer than doing the same work itself, and the app server 35.3s (69%) longer. A child starts from a fresh context, so it re-reads what the parent already had, and the parent spends calls starting and collecting it. The suite measures that orchestration cost; work long enough for parallel children to win back their start-up time is not in it.

## Resource use

In one census run with four children, graff's own process peaked at 30 MB resident (53 MB with the Python a child was running at that moment), and the whole process tree used 0.9 s of CPU over 67 s of wall time. The app server's own process held about 270 MB, not counting its code-mode host or the MCP servers it started.

## Method

Each round interleaved the arms task by task (`--interleave`, 6 or 8 workers). Costs are list prices from graff's pricing table (`gpt-6-astra`: $10 per million input tokens, $1 cached, $50 output) applied to each harness's reported usage. Per-run data: [`results-astra.json`](results-astra.json).

## Caveats

Two or three runs per task: a difference of a few seconds on one task is noise. The app server ran with a signed-in Codex home, which can start MCP servers of its own; graff ran with none but the task's. The `subagents` tasks are short, so they show orchestration overhead, not the payoff of parallel work on long tasks.

## Reproduce

```sh
cd graff-evals
./run.py --suite core --harness graff-repl,codex-app-server --model gpt-6-astra -j 8 --interleave
./run.py --suite mcp --harness graff-repl,codex-app-server --model gpt-6-astra -j 8 --interleave
EVAL_TRACE_DIR=<out>-codex-traces ./run.py --suite subagents,subagents-solo --harness graff-repl,codex-app-server --model gpt-6-astra -j 6 --interleave --output-root <out>
python3 subagent_split.py <out>
```
