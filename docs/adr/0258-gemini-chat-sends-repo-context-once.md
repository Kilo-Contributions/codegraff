# 0258. Gemini on the Codegraff chat wire sends the repo context once

Status: accepted 2026-10-06

## Context

Gemini on the Codegraff chat wire is stateful: each request continues the
conversation on the server and carries only the new turn, but the system
prompt and the tool catalog travel again with every request. Whatever sits in
the system prompt is paid for on every request of a session.

In a real repository a large share of that system prompt is per-repo context:
the project-instructions file and the project layout. In this repository they
are about half of the system prompt, and they never change during a session
except through a compaction fold (ADR 0208) or a resumed layout (ADR 0109).

ADR 0243 already moves exactly these blocks out of the instructions on the
Responses wires, as one developer item ahead of the conversation. A developer
or system message cannot do that on this wire: they join the system prompt.

## Decision

On the Codegraff chat wire, for `gemini-` model ids and root turns, the
per-repo context leaves the system prompt and rides as the conversation's
first user message, framed as standing context rather than a request. It uses
the same blocks and the same split as ADR 0243. Because the server keeps the
conversation, that message reaches the model once per session; the system
prompt that every later request repeats no longer holds it.

Other chat routes, the Responses wires and sub-agents are unchanged.

## Consequences

Every request after a session's first carries a smaller system prompt, by the
size of the project instructions and layout; small repositories gain little.
The system prompt is also identical across repositories.

Project instructions now arrive in a user turn on this route, the place other
coding harnesses put them. Compliance with checkable rules in a project
instructions file (a required first line, tab indentation, a commit-subject
prefix) was the same before and after in eval runs. Revisit if
instruction-following on this route degrades, or if the route stops
continuing conversations server-side.
