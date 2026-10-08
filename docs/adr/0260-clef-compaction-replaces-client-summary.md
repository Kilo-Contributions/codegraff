# 0260. Client-summary compaction goes through the gateway's Clef endpoint when eligible

Status: accepted 2026-10-06; default superseded by 0261 (Clef stays opt-in, the client summary is the compactor)

## Context

`compact()` summarized history with the session model: one request asked to
both discover working state and narrate it, and the summarizer optimized for
a readable account — dropping the exact lines, ruled-out approaches, and
identifiers the next turn needs verbatim (the retry-loop failure the
`evals/compact_ab` comparison documents). The two-pass mixture
(`GRAFF_COMPACT_MIX`) narrows that loss but still rewrites history as prose.

The gateway already serves `POST /v1/compact`: Clef decision models score
every tool call with keep/drop (`noul`) questions and prune only tool
calls/results. Text messages stay verbatim and in order — nothing is
rewritten. Measured on the gateway's fixtures: clef keep-recall 89%, probes
100%, reduction ~21%.

## Decision

- `GRAFF_CLEF_COMPACT=1` arms the gateway path (default off until measured).
  Eligible sessions are `codegraff`-provider with a credential; review turns
  never compact. `agent_clef_compact.zig` translates wire history to the
  gateway transcript shape, POSTs `/v1/compact` (model `clef-flash`, prune
  mode), and applies the returned decisions by `tool_use_id`/`call_id`
  (`drop_call` removes both halves, `drop_result` truncates the output).
- It replaces ONLY the client summarizer: the hook sits at the top of
  `compact()`, and every OpenAI-family server path (direct-OpenAI standalone
  `/responses/compact`, Codex/ChatGPT in-stream directive, xAI explicit
  endpoint, blob-anchored histories) never reaches it. Any gateway failure —
  or a prune that removes nothing — falls through to the existing summary,
  transactionally, so a broken endpoint can never wedge the session.
- Privacy: the transcript (tool output included) is sent to the gateway's
  hosted decision models. The knob is opt-in; enabling it is the
  disclosure.

## Consequences

One extra gateway call per compaction when armed (input tokens at clef-flash
rates, output free — far cheaper than a frontier summary). Unknown decision
actions are applied as keep (safety-first, mirroring the gateway's drop bar).
Revisit when the arm has production recall numbers against the summary
baseline; the `#compact-ab` telemetry shape (`prune_items` vs
`summary_chars`) fits a third arm unchanged.
