# 0217. A follow-up typed mid-reply supersedes the streaming reply

Status: accepted 2026-09-29

## Context

A follow-up typed during a turn used to wait. The line REPL delivered it at
the next step boundary, after the model had finished its whole reply and its
tools had run. The TUI held it until the whole turn ended. Only GPT-6 over the
Responses WebSocket could act on it mid-reply, through the provider's
server-side `response.steer`. A model spending a minute on a reply the user
had already asked to change kept going to the end.

The unreal-agent harness treats input that lands during an active model
request as a reason to cut that request and rebuild it with the input.

## Decision

- While the root's own turn request is streaming (SSE, HTTP/2, or a WebSocket
  without server-side steer), a pending plain follow-up cuts the stream
  (`stream_aborted = steered`). The partial reply was never committed to
  history, so it is dropped. The follow-up is delivered and the request
  rebuilt (`steer_now.zig`, `request()`'s rebuild loop). The transcript says
  "follow-up received — restarting the reply".
- Not superseded: compaction, titles, judges, children, a stream whose early
  async tools already started (ADR 0177), and GPT-6 on the Responses
  WebSocket, which steers server-side. Tools that are already running finish,
  and the follow-up lands at the next step boundary as before.
- A force follow-up (double Enter in the line REPL, empty Enter in the TUI)
  still interrupts the turn.
- In the TUI, Enter mid-turn hands plain text to the running turn. Commands,
  image chips and `/btw` asides still wait for the turn to end. A follow-up
  the turn ended before delivering runs as the next turn.
- ACP clients are unchanged: a `session/prompt` sent during a turn still
  queues as the next request.

## Consequences

- The cut request's output tokens are billed and thrown away.
- The partial reply on screen is replaced by the new one. That is the point:
  the user asked for something different.
- Revisit for ACP once a client can say that a prompt joins the running turn.
