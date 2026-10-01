# 0233. No tool result the model already has

Status: accepted 2026-10-02

## Context

Reading a week of session transcripts tool by tool showed two results that
cost the model without telling it anything new.

- **A one-second shell wait.** Some models send `timeout: 1000` on many shell
  commands, as a habit of reading output after a second rather than as a
  request to stop waiting. graff honored it as the foreground wait, so about
  half of those commands (`git`, `gh`, `node`, `python3`) were parked after one
  second. On an interactive surface a park ends the turn (ADR 0154) and the
  result arrives on a later turn: the agent stopped mid-task for a command
  that would have finished in two seconds, and the next request re-sent the
  whole context.
- **`todo_write` echoing the list.** The result was the full rendered
  checklist, which the model had just sent as the call's arguments, and every
  later request carried it again. The replies ran nearly twice the size of
  the calls.

## Decision

- Interactive roots (TUI, line REPL, GUI, ACP) ignore a model's `timeout`:
  the foreground wait is the 15s of ADR 0154. A park there yields the turn,
  so a shorter wait only stops the agent sooner.
- Unattended roots still honor a shorter `timeout`, because a parked job lets
  the run keep working (ADR 0215), but not below 5s
  (`exec_bash.min_model_wait_ms`). The shell tool's description says both.
- `todo_write` answers the model with counts (`Todo list saved: N done, N in
  progress, N pending.`), the items graff kept that the call left out
  (finished items, open verification), and the existing notes about dropped or
  kept work. The rendered list still goes to the UI through
  `todo_list_updated`. A rejected write answers as before.

## Consequences

- A command that runs past 5s (unattended) or 15s (interactive) still parks;
  `run_in_background` remains the way to start work that should not hold the
  turn.
- A model that wants its plan in front of it again calls `todo_read`.
- `scripts/test-shell-wait-and-todo-reply.py` sends a two-second command with
  `timeout: 1000` and a todo write through a scripted REPL and checks both
  results; it fails on a build without this change.
