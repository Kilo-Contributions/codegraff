# 0216. /loop is retired; /goal is the autonomous run

Status: accepted 2026-09-29

## Context

`/loop [30m] <prompt>` ran the same plan-act-verify controller as `/goal`
without adopting a standing objective. After a working turn the controller
queued a continuation turn with a steering note and a pacing line, up to 25
times. It existed only in the line REPL: the TUI chat, ACP clients, the SDKs
and `-p` never had it.

The two things it offered are covered elsewhere now. Waiting for background
work is how runs work: interactive surfaces wake when a job exits, and
headless runs wait until idle (ADR 0215). Working autonomously toward an
objective is `/goal`, which runs on the same controller with a completion
gate. What `/loop` added on top was continuation nudges for a prompt with no
objective to check them against. Such a run ends as `idle` on its first
zero-tool turn, or after 25 nudges.

## Decision

- Remove `/loop` from the line parser, the command catalog, help and the TUI
  chat. Typing `/loop` prints a one-line notice that points at `/goal`, and
  makes no model call.
- `/goal [30m] <objective>` keeps the controller, the continuation steering,
  the pacing line and the #1278 hold for its own background work.
- The controller marks its continuation turns itself
  (`goal_pacing.autonomousFromLine(..., continuation)`). The synthesized line
  no longer carries a `/loop ` prefix for the parser to recognize, so no typed
  line can pass for a continuation.
- The armed budget line reads `run budget: 30m`.

## Consequences

- One autonomous entry point to document and test. The tier-1 invariant that
  kept `/goal` and `/loop` in step now pins that `/loop` does not come back as
  a second entry point.
- Someone who wants continuation without a standing objective phrases the
  prompt as a `/goal`; the objective then scopes the completion gate.
- Release notes and the changelog keep their historical `/loop` entries.
