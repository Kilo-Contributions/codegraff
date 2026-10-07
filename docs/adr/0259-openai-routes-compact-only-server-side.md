# 0259. First-party Responses routes compact only server-side, and the blob is metered as state

Status: accepted 2026-10-07

## Context

On the first-party Responses routes (the direct API, Codegraff's GPT models and
the ChatGPT-plan sign-in), compaction is the provider's own: the
`context_management` directive compacts in-stream, `/responses/compact` returns
a canonical window, and either one leaves an opaque `compaction` item whose
`encrypted_content` carries the pruned state (ADR 0089).

The context meter estimated that item like any other JSON, at bytes/4. The
encrypted state is much denser than text: the provider bills a blob-anchored
history at a small fraction of what bytes/4 says. `replaceContextTokens` keeps
the larger of the local estimate and the reported usage, so once a long
session's blob grew past roughly 95% of the window in bytes/4 terms, the meter
read over the window on every step. With the history already anchored on the
blob, `pruneIf` had nothing to drop, so `autocompactIf` forced another server
pass. That pass returned a blob of the same size, and the next step did it
again. Every tool call cost a full compaction request, and the session never
got out of the loop.

Two paths could also still reach the client summarizer on these routes: a
near-wall compaction before any blob existed went to `compact()`, and a failed
server pass fell back to it.

## Decision

- `context_tokens` counts `compaction` and `compaction_summary`
  `encrypted_content` at `compaction_state_bytes_per_token` (16), the way
  inline image payloads are counted separately. That stays above the
  billed ratio seen in practice. The provider's reported usage is still the
  authority above that floor. Reasoning items keep the text rate, because a
  full resend pays for them again.
- `server_compact.serverOnly(provider)`: on the server arm, a first-party
  route compacts only into the provider's own state. `compactOrRecover` takes
  the server path whether or not a blob exists yet, and a failed server pass
  reports its error instead of falling back to a client summary. The existing
  recovery policy (the emergency trim at the wall) is unchanged.
- `GRAFF_SERVER_COMPACT=0` still opts these routes back into the client
  summarizer. xAI and third-party Responses hosts are unchanged (ADR 0002).

## Consequences

A blob-anchored session's meter tracks what the provider bills, so it
compacts when the window is genuinely full rather than on every step.

The client summarizer, and anything that replaces it at the top of `compact()`,
can no longer run on these routes while the server arm is on. If the server
cannot compact, the user sees the failure rather than a silent summary that
would discard state the provider still holds.

If the provider's blob ever becomes less dense than 16 bytes per token, the
local estimate under-reads until the first usage sample of the next request;
the in-stream directive still compacts at its own threshold, so the cost is a
late meter, not an over-window request. Revisit the ratio if the reported
input for a blob-anchored history ever exceeds the local estimate.
