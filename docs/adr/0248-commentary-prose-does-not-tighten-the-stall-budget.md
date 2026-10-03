# 0248. Commentary prose does not tighten the stall budget

Status: accepted 2026-10-03

## Context

ADR 0241 tightens the between-frames read budget while prose streams and gives
the full budget back when the prose item closes. On the Codex Responses
backend, GPT-6 models write a commentary heads-up (`phase: "commentary"`)
before a batch of tool calls. The server streams that heads-up, then holds
the message open — no `output_text.done`, no `output_item.done` — while the
model composes the calls, and releases the message close and every call
together once they are composed. A batch that takes longer than the tightened
budget (a quarter of the configured one) was killed as a stall and re-sent,
paying the whole generation again. Every stall seen in evaluation runs since
ADR 0241 had this shape: a few seconds of heads-up text, then the tightened
budget expiring on a healthy compose.

## Decision

- Track whether the open output item is a commentary message (`Phase` in
  `agent_ws_signal.zig`), fed WebSocket frames and SSE `data:` lines alike.
- Commentary prose still counts as visible text (first-token time, traces),
  but it does not tighten the budget: the full configured budget stands until
  the item closes, as it does for a silent reasoning phase.
- Final-answer messages, messages without a phase, and whitelisted
  tool-argument prose (`attempt_completion`, `ask_user`) tighten as before, so
  a stream that dies mid-answer is still caught at the tightened budget.

## Consequences

A stream that dies during a commentary heads-up waits the full budget instead
of a quarter of it, the same wait a silent reasoning phase already gets. The
trace's first-text note says which regime the budget is in.
