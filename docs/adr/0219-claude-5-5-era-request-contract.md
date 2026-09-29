# 0219. Claude 5.5-era models: the request contract

Status: accepted 2026-09-30

## Context

Claude Opus 5.5, Sonnet 5.5 and Fable 5.1 change the Messages API contract
graff relied on:

- **Forced tool use returns a 400.** `tool_choice` `any` or `tool` is
  rejected. graff forces a tool call under `--strict`, under `--eval`, and
  after named-work nudges.
- **Thinking is always on** on Opus 5.5 and Fable 5.1, and `max_tokens`
  covers thinking plus the answer. graff sent a flat 16K. Anthropic measured
  that cap ending a large share of agentic attempts on these models, at no
  saving per solved task.
- **Replayed thinking is bound to its prefix.** A replayed thinking block is
  checked against everything before it: `system`, `tools` and the earlier
  messages. graff edits that prefix mid-session. Tools change when an MCP
  server joins, and compaction and history repair rewrite earlier messages.
  Accounts created from 31 August 2026 get a 400 for this by default.
- **Effort is the only thinking control,** set through
  `output_config.effort`. Opus 5.5 defaults to `medium`. graff never sent
  effort to Claude, so `/effort` did nothing there.
- **A safety refusal** ends with `stop_reason: "refusal"` and a
  `stop_details.category`.

Separately, graff's retry-without ladder drops a rejected option (a forced
tool, an effort level, an output format) and retries. It only ran for
OpenAI-shaped errors, so every Claude error failed the request.

## Decision

- **Per-model rules.** `claude_wire.zig` keys them on family and version
  (`claude-<family>-<major>[-<minor>]`), so later releases inherit them.
- **Forced tools.** 5.5-era models run `auto` (soft-strict) and keep their
  thinking. Older models are forced as before.
- **Thinking binding.** Fable 5.1, Opus 5.5, Sonnet 5.5 and later get
  `thinking.block_binding.prefix_mismatch_behavior: "drop_block"`, with
  `anthropic-beta: thinking-binding-controls-2026-08-01`. A prefix edit then
  drops the stale thinking instead of failing the request. Older models, which
  do not run the check, get neither.
- **Effort.** `output_config.effort` goes to models that take it: Opus 4.5 and
  later, Sonnet 4.6 and later, Fable, and Mythos. It shares one `output_config`
  object with a structured-output `format` when there is one. graff's default
  (`medium`) is left off, so each model keeps its own default. `ultra` maps to
  `max`.
- **max_tokens.** 64K on models with a 128K ceiling, and the full 128K at
  `xhigh`, `max` and `ultra`, as Anthropic advises for agentic work. Other
  models keep 16K. graff always streams, which responses this size need.
- **One retry ladder.** Every error shape goes through it: Anthropic JSON
  errors, streamed error events, and OpenAI envelopes. An effort rejection is
  recognized before the output-format fallback, since Claude names both
  inside `output_config`.
- **Refusals.** A refusal ends the turn with a line naming the category. The
  refused reply stays out of history, and the turn is never read as an empty
  reply to re-send.
- **Defaults and lineup.** The Anthropic default model is `claude-opus-5-5`.
  The subagent ladder is `claude-opus-5-5` → `claude-sonnet-5-5`, and
  `claude-sonnet-5-5` is the vision seat. The new lineup has prices and
  offline catalog rows.

## Consequences

- A dropped thinking block costs the model that earlier reasoning, but the
  request succeeds.
- Not done yet:
  - Keeping thinking instead of dropping it, by freezing `system` and `tools`
    and using inline tool additions and mid-conversation system messages.
  - Showing text written between tool calls via the `updates` display.
  - Pricing 1-hour cache writes at 2× (they are counted at 1.25×).
  - Tool search with deferred loading.
  - Task budgets.
  - An elapsed-time clock.
  - Keep-alive cache warming.
  - Server-side refusal fallback.
  - Fast mode.
- The request shapes are unit-tested. CI does not call the live API.
