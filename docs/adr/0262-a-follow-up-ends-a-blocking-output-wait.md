# 0262. A queued follow-up ends a blocking output wait

Status: accepted 2026-10-07

## Context

ADR 0010 makes `action=output` with `wait_ms > 0` on a finite job block until
the job exits, with Esc as the only way out. A follow-up the user queued while
that wait ran was not delivered until the job finished, which could be hours.
The foreground wait already treated a queued follow-up as the signal to move
the job to the background (`job_wait.followup_pending`); the explicit output
wait ignored it, and ACP never raised it for a prompt that arrived mid-turn
(#1522).

## Decision

- A blocking output wait returns a snapshot as soon as a follow-up is queued,
  exactly as it does on Esc. The job keeps running and still reports on exit.
- An ACP `session/prompt` that arrives while a turn is active raises the same
  follow-up signal. It does not cancel the turn; only `session/cancel` does.
- The signal clears when the next root turn is prepared.

## Consequences

ADR 0010's single-hop wait stands while nobody is waiting on the agent: no
polling, one wait covers exit. A user who speaks while a wait runs is heard at
the next step instead of after the job ends. Revisit if a client needs to queue
prompts behind a wait on purpose; it would need a distinct "queue only" signal.
