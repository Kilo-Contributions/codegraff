# graff vs Claude Code, OpenCode 2 and pi on a gateway model

Measured 2026-10-01. One model, served through the Codegraff gateway, ran the same 21 tasks in each harness, side by side, on one machine and one gateway key.

| Arm | What ran |
| --- | --- |
| graff | The ADR 0231 build (#1449) as a scripted `graff repl` (the `graff-gateway-repl` harness). |
| Claude Code | Claude Code 2.1.286: `claude -p --output-format stream-json --verbose --dangerously-skip-permissions`, with the task's `.mcp.json` as its only MCP config, through [`graff-evals/claude_code_run.py`](../../graff-evals/claude_code_run.py). The gateway takes chat completions only, so Claude Code reached it through a local LiteLLM 1.103.2 proxy that turns Anthropic Messages requests into chat completions. |
| OpenCode 2 | `@opencode/cli` 2.0.21: `opencode run --standalone --auto --format json`, through [`graff-evals/opencode2_run.py`](../../graff-evals/opencode2_run.py). |
| pi | pi 0.84.2 (the `pi-codegraff` harness). pi has no MCP client, so it ran the 11 coding tasks only. |

All four send the same model id to the same gateway with the same key, and each runs at its own defaults. Claude Code's background requests for a small model went to the same model.

## Results

All 21 tasks (pi: the 11 coding tasks), mean per task over 3 runs of each:

| | Pass | Wall per task | Input read from cache | Output tokens per task | Model calls per task |
| --- | ---: | ---: | ---: | ---: | ---: |
| graff (ADR 0231 build) | 63/63 | 8.7s | 95% | 573 | 3.5 |
| Claude Code | 63/63 | 13.2s | 60% | 926 | 3.5 |
| OpenCode 2 | 63/63 | 14.1s | 86% | 978 | 4.3 |
| pi | 33/33 | 6.0s | 76% | 262 | 2.8 |

By suite:

| Suite | graff (ADR 0231 build) | Claude Code | OpenCode 2 | pi |
| --- | ---: | ---: | ---: | ---: |
| core (11 coding tasks), wall | 7.0s | 6.0s | 6.8s | 6.0s |
| core (11 coding tasks), pass | 33/33 | 33/33 | 33/33 | 33/33 |
| mcp (10 MCP tasks), wall | 10.6s | 21.2s | 22.1s | — |
| mcp (10 MCP tasks), pass | 30/30 | 30/30 | 30/30 | — |

**Against Claude Code.** graff is 34% faster per task over all 21 tasks (8.7s against 13.2s). The gap is the MCP tasks, which graff finishes in half the time (10.6s against 21.2s). Claude Code keeps every MCP result whole in its context: 179k prompt tokens per MCP task against graff's 44k, about 40k per call against 10k, and it writes nearly twice the output (1,645 tokens against 882). graff slims large list results and often fetches, reduces and writes the report in one `rlm` script. On the coding tasks Claude Code is faster (6.0s against 7.0s); one 11.7-second gateway response on graff's one-call `exact-reply` accounts for about 0.3s of that.

**Against OpenCode 2 and pi.** graff takes 38% less time than OpenCode 2 over all tasks (8.7s against 14.1s) and about half on the MCP tasks (10.6s against 22.1s); OpenCode 2 is slightly faster on the coding tasks (6.8s against 7.0s). pi ties Claude Code as the fastest on the coding tasks (6.0s), with the smallest prompt.

## Per task

Wall time is the mean of 3 runs.

| Task | Suite | graff (ADR 0231 build) | Claude Code | OpenCode 2 | pi |
| --- | --- | ---: | ---: | ---: | ---: |
| [`csv-sum`](../../graff-evals/tasks/11-csv-sum.json) | core | 8.4s | 6.9s | 5.9s | 4.7s |
| [`dead-code`](../../graff-evals/tasks/12-dead-code.json) | core | 5.3s | 6.0s | 6.8s | 7.8s |
| [`exact-reply`](../../graff-evals/tasks/01-exact-reply.json) | core | 6.2s | 1.7s | 1.7s | 1.9s |
| [`file-ops`](../../graff-evals/tasks/03-file-ops.json) | core | 6.8s | 6.0s | 5.8s | 3.5s |
| [`fix-fib`](../../graff-evals/tasks/02-fix-fib.json) | core | 8.7s | 6.4s | 7.9s | 12.0s |
| [`git-ops`](../../graff-evals/tasks/08-git-ops.json) | core | 4.1s | 4.6s | 6.3s | 7.1s |
| [`json-transform`](../../graff-evals/tasks/04-json-transform.json) | core | 5.8s | 6.7s | 6.3s | 5.0s |
| [`linear-issues`](../../graff-evals/tasks/24-linear-issues.json) | mcp | 8.8s | 18.6s | 22.9s | — |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | mcp | 11.1s | 20.1s | 18.7s | — |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | mcp | 10.2s | 19.3s | 23.0s | — |
| [`linear-quiet`](../../graff-evals/tasks/28-linear-quiet.json) | mcp | 9.2s | 28.0s | 21.2s | — |
| [`linear-quiet-warm`](../../graff-evals/tasks/29-linear-quiet-warm.json) | mcp | 9.8s | 19.3s | 21.4s | — |
| [`linear-reduce`](../../graff-evals/tasks/32-linear-reduce.json) | mcp | 11.5s | 21.7s | 22.8s | — |
| [`linear-reduce-warm`](../../graff-evals/tasks/33-linear-reduce-warm.json) | mcp | 10.1s | 23.5s | 19.2s | — |
| [`linear-sidecar`](../../graff-evals/tasks/26-linear-sidecar.json) | mcp | 11.2s | 21.5s | 22.3s | — |
| [`linear-split`](../../graff-evals/tasks/27-linear-split.json) | mcp | 15.6s | 20.3s | 26.5s | — |
| [`linear-warm`](../../graff-evals/tasks/25-linear-warm.json) | mcp | 8.8s | 19.8s | 23.4s | — |
| [`recall-noise`](../../graff-evals/tasks/09-recall-noise.json) | core | 3.5s | 3.7s | 5.7s | 3.5s |
| [`refactor-rename`](../../graff-evals/tasks/06-refactor-rename.json) | core | 10.7s | 6.5s | 10.6s | 7.9s |
| [`regex-count`](../../graff-evals/tasks/05-regex-count.json) | core | 10.5s | 7.8s | 8.7s | 6.6s |
| [`write-tests`](../../graff-evals/tasks/07-write-tests.json) | core | 7.0s | 9.3s | 9.2s | 6.4s |

`results.json` has every run: pass, wall time, model calls, and input, cached input and output tokens. An earlier run of graff, OpenCode 2 and pi on the same model is [graff-vs-opencode-and-pi](../graff-vs-opencode-and-pi/RESULTS.md).

## Method

- **Tasks.** 11 coding tasks (`core`) and 10 tasks against a Linear-shaped MCP server (`mcp`, [`scripts/linear_fixture_mcp.py`](../../scripts/linear_fixture_mcp.py)), from [`graff-evals/tasks`](../../graff-evals/tasks). Each task passes or fails on its own check.
- **Order.** 3 runs per task and arm. graff, Claude Code and OpenCode 2 were interleaved task by task (`run.py --interleave`), 6 runs at a time; pi ran its coding tasks afterwards. Each arm made one unscored request first.
- **Wall time.** The runner's clock around each process, start to exit.
- **Tokens.** Prompt tokens include cached ones in every arm. Claude Code's come from its stream's final result (session totals; Anthropic's `input_tokens` leaves out cache reads and writes, so the wrapper adds them back); its model calls are the distinct API responses. No list cost: the gateway's prices are not public list prices.

## Caveats

- **Claude Code ran through a translation proxy.** The proxy itself added no measurable time: a small request took 1.10s median through it against 1.61s sent straight to the gateway, because it keeps its connection to the gateway open. But Claude Code's own prompt-cache breakpoints do not survive the translation; the gateway applies its own caching, as it does for the other three. Only 49% of Claude Code's MCP input was read from cache (graff's: 96%), so against an endpoint that takes Anthropic Messages directly, Claude Code's MCP times would likely be better. The MCP gap here is an upper bound. Claude Code's token-count requests also fail through the proxy; it carried on without them.
- **pi runs only the coding tasks.** It has no MCP client.
- **One model.** Harness differences can look different on another model; the [Codex comparison](../graff-vs-codex-app-server/RESULTS.md) runs graff and pi on a different one.
- **Small sample.** 3 runs per task, one machine, one key. A second or two per task is within run-to-run noise.

## Reproduce

```sh
cd graff-evals
# CODEGRAFF_API_KEY set. Claude Code needs an Anthropic Messages endpoint; with LiteLLM in front
# of the gateway's chat completions:
#   model_list:
#     - model_name: "*"
#       litellm_params: {model: "openai/<gateway model>", api_base: "https://gateway.codegraff.com/v1",
#                        api_key: "os.environ/CODEGRAFF_API_KEY"}
#   litellm_settings: {use_chat_completions_url_for_anthropic_messages: true}
#   litellm --config config.yaml --host 127.0.0.1 --port 4000
# then ANTHROPIC_BASE_URL=http://127.0.0.1:4000 and any ANTHROPIC_AUTH_TOKEN for the claude-code arm.
# OpenCode 2 and pi set up as in evals/graff-vs-opencode-and-pi. Keep --output-root outside any
# repository, with scripts/linear_fixture_mcp.py copied to <parent of output-root>/scripts/.
TASKS="--task exact-reply --task fix-fib --task file-ops --task json-transform --task regex-count \
  --task refactor-rename --task write-tests --task git-ops --task recall-noise --task csv-sum \
  --task dead-code --task linear-issues --task linear-warm --task linear-sidecar \
  --task linear-split --task linear-quiet --task linear-quiet-warm --task linear-nohint \
  --task linear-nohint-warm --task linear-reduce --task linear-reduce-warm"
python3 run.py --harness graff-gateway-repl,claude-code,opencode2 --model <gateway model> --suite core,mcp $TASKS \
  --reps 3 -j 6 --interleave --output-root /path/outside/repo/gateway
python3 run.py --harness pi-codegraff --model <gateway model> --suite core $TASKS \
  --reps 3 -j 6 --output-root /path/outside/repo/gateway-pi
```
