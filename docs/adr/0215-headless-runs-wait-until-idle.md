# 0215. Headless runs wait until their background work reports

Status: accepted 2026-09-29

## Context

A long command moves to the background after the foreground wait (15 s under
lean `-p`, 120 s elsewhere), and a subagent can run in the background. Each
reports when it finishes: a job posts an exit notice (`job_notify.zig`) and a
subagent leaves a report. Interactive surfaces deliver that as an idle wake:
the TUI, the line REPL and ACP start a new turn with it (ADR 0118, ADR 0154).

Headless surfaces have no idle wake. `-p`, `--json` (the SDKs), `graff serve`
and piped stdin ended the run on the model's first reply without tool calls.
The tool results tell the model it is "notified on exit — do not poll", so it
ends with "the build is running; I will report when it finishes". That ended
the run, and the notice was never read. Under `-p` the process then exited.

The unreal-agent harness makes the opposite the rule for every run. Tool calls
are asynchronous and each result wakes a turn. Ending a turn with no tool
calls while calls are running sleeps until one finishes; ending it with
nothing running ends the session. A heartbeat wakes the model after ten silent
minutes.

## Decision

A headless root turn runs until idle (`run_idle.zig`).

- Where a plain final would end the root turn, after the empty-reply retry and
  after the one open-checklist reminder (ADR 0064), the run looks for live
  background work: a running shell job that will post an exit notice, and a
  background subagent the root started. A server never reports, so a job that
  is persistent, pinned, detached, or whose process group listens on a TCP port
  (lsof) does not count.
- With live work, the run waits. A queued exit notice or a finished subagent's
  report continues the turn, and the next request carries it. A notice that
  landed during the final model call is delivered the same way, so no result
  is lost at the end of a run.
- After `GRAFF_HEARTBEAT_SECS` (default 600, 0 turns it off) with no news, a
  heartbeat notice names the running work and wakes the model to check on it,
  stop it, or end its reply to keep waiting. Three heartbeats in a row with no
  result and no tool call end the wait.
- The wait ends early on cancel, when a `--json` client sends its next request
  (that request runs, and its first step boundary delivers whatever reported),
  or when the run budget cannot buy another request.
- A headless root also receives a finished background subagent's report at
  each step boundary, capped at 6 KB, as an interactive root does.
- The system prompt says so (the `background` segment, gated on local tools):
  background work reports back when it finishes, a reply that ends while it
  runs waits for the result, and a reply with nothing running ends the run.

Interactive surfaces are unchanged: their turn ends and the idle wake starts
the next one.

## Consequences

- This amends ADR 0064's "no global worker wait" for headless roots. That rule
  kept unrelated jobs and long-lived servers from holding a turn open. A
  headless process runs one session, so every job in it belongs to this run,
  and servers are excluded.
- The operation-priorities proposal avoids periodic heartbeats by default,
  because a wakeup can spend a request without new information. Here the
  heartbeat is the only way out of a wait on work that never reports. It
  costs at most one request per ten silent minutes, and three quiet
  heartbeats end the wait.
- A headless run lasts as long as its background work. The heartbeat, the
  quiet-heartbeat cap, the run budget (`--max-model-calls`) and the caller's
  own timeout bound it.
- A long-lived process the lsof check does not see as a server (no lsof on the
  host, or not listening yet) holds the run until it exits or the
  quiet-heartbeat cap ends the wait.
- A `--json` turn's terminal `turn` event arrives after its background work
  reports. SDK loops already wait for `turn` or `error`.
- Revisit if a caller needs a headless run that returns with work still
  running. That would be an opt-out flag, not a return to losing results.
