# 0247. Parked work is named above the prompt

Status: accepted 2026-10-03

## Context

ADR 0154 parks a shell command that outlives the interactive foreground wait
and hands the prompt back; the command's exit wakes the session, which then
continues on its own. The yield printed one generic line ("Background work
continues separately…") and returned to `›`. It never said what was running
or that the session would resume by itself, so a parked turn read as graff
stopping mid-task, with an unfinished checklist still drawn above the prompt.

## Decision

- `background_wait` names the live work whose exit wakes the session: running
  shell jobs that will post an exit notice and this session's unfinished
  agents. A command is shown as its first line, clipped; finite work leads and
  the rest are counted ("zig build and 2 more"). Job ids stay out: they are
  session handles the model already has from the tool result.
- The standing block above `›` draws `↻ waiting on <work> — graff continues
  when it finishes` whenever such work is running, below the checklist or on
  its own, on every prompt redraw.
- The yield itself prints only what that line will not say: a persistent
  server never exits to wake the session, so it is named as running in the
  background with no promise to continue. The recorded turn result names the
  work either way.
- A wake that resumes the session prints `↻ <command> exited 0 — continuing`
  (or killed / stopped idle / `agent N completed`) before the turn runs.

ACP sessions are unattended and never yield (ADR 0154), so nothing changes
there.

## Consequences

One extra line above `›` while parked work runs, and one when it resumes. The
model-facing tool results and wake notices are unchanged.
