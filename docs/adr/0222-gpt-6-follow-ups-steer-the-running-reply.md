# 0222. GPT-6 follow-ups steer the running reply

Status: accepted 2026-09-30

## Context

ADR 0217 left GPT-6 on the Responses WebSocket to act on a follow-up
server-side, through `response.steer`. graff sent the steer and followed the
protocol no further:

- `response.steer.failed` was ignored. The follow-up was gone, and the turn
  waited for a continuation that never came until the stall budget ended it.
- A response that ends in client tool calls holds an accepted steer until
  their outputs arrive (`response.steer.pending`). The turn kept reading for
  a continuation the server only starts after those outputs, and stalled.
- The steered text never entered history, so a full resend, `/resume` or
  compaction lost it.
- Later steers kept targeting the first response, not the continuation.
- Every request carried the server-compaction directive
  (`context_management`), and the server refuses to steer a request that
  carries it (`steering_not_supported`).

## Decision

- A root turn request with a GPT-6 model on Codex or Platform OpenAI steers.
  Its body leaves the server-compaction directive off until the context meter
  comes within a quarter of the compaction threshold, where the directive
  starts to matter. From there compaction wins, and a follow-up supersedes
  the reply as in ADR 0217. Compaction, titles, judges and children never
  steer.
- Queued follow-ups go out as `response.steer` on the live response (the
  newest `response.created`) while it streams. The terminal frame never
  carries one; the step boundary delivers it instead.
- Each steer is tracked until the server answers it:
  - Accepted: the server ends the response (`incomplete` with reason
    `steered`, or `completed` when the item in progress was its last) and
    streams a continuation on the same socket. The read loop follows it, and
    the continuation's inter-frame budget starts over.
  - Accepted on a response that ends in client tool calls: the steer waits
    for their outputs. The read loop stops so the tool loop runs, and the
    chained output request does not repeat the steer; the server prepends it.
  - Failed: the text goes back to the head of the follow-up queue for the
    next step boundary or turn. `steering_not_supported` turns steering off
    for the session.
- An applied steer joins history as a user message where the server applied
  it: ahead of the continuation's items, or after the tool calls it waits on.
- A steer lives only on its socket. When the stream fails (a drop, a stall,
  Esc, a failed response), every steer it carried goes back on the queue.
- The last response's usage drives the context meter. The responses a steer
  ended are billed without moving it.

## Consequences

- Near the compaction threshold, GPT-6 follow-ups supersede instead of
  steering.
- A follow-up typed while the model reasons goes out with the next frame;
  reasoning summaries keep frames coming.
- The Codex mock (`scripts/codex_ws_mock.py`) plays the server side of
  steering, and `scripts/test-tui-steer-gpt6.py` covers the continuation,
  pending and failure paths end to end.
