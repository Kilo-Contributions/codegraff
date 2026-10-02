# 0235. MiMo thinks only at high effort

Status: accepted 2026-10-02

## Context

ADR 0192 made MiMo's thinking a binary switch and kept every positive effort
as On. graff's default effort is medium, so every MiMo request went out with
thinking enabled.

Thinking dominated MiMo's wall time. One reply to a one-word prompt took
several seconds with thinking enabled and under two without it. On tasks that
read an MCP server, each call thought at length before acting, and a single
call could think for minutes. Runs that did the same work with thinking off
finished in a fraction of the time and passed at least as often. Thinking off
did take more calls, but each was short. Turning thinking on only for a
turn's first request, or leaving the field to the model's own default (which
thinks), stayed slow.

## Decision

On the MiMo routes (direct Xiaomi and the Codegraff gateway), only `high` and
above turn thinking on. `minimal`, `low` and `medium`, which includes graff's
default, mean Off: Chat requests send `thinking.type=disabled`, and Responses
requests send `reasoning.effort=none`. The picker still offers Off and On, and
the status line and ACP report the default as Off. `/effort high` (On), a
worker's effort pin, and a Jev choice of `high` still turn thinking on.

This replaces ADR 0192's "existing positive values still mean On" for the
levels below high.

## Consequences

MiMo no longer reasons by default, so a hard problem gets the model's direct
answer unless someone picks On or Jev raises the effort. A saved `low` or
`medium` from another model now means Off when the session moves to MiMo.

Revisit if MiMo's thinking becomes bounded by effort, or if traces show
default-effort MiMo runs failing where thinking would have passed.
