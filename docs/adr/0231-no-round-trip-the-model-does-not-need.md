# 0231. No round trip the model does not need

Status: accepted 2026-10-01

## Context

Run on the same model and the same tasks as the Codex app server, graff made
more model calls per task. Every call pays a wait for the first token and
then for every output token, so a call is seconds of wall time. The
transcripts showed where the extra calls went, and none of them did work the
task asked for.

- **Loading what the prompt names.** "The linear server … load its schemas"
  cost a `load_tool_schemas` call before the first real call, and "split the
  work across subagents" cost one for the folded `subagent` tool.
- **Checking that a path is free.** The prompt said `write_file` was "only
  for new files", so in close to half of the runs that wrote a file the model
  first ran `test -e`, `cat` or `read_file` on the target.
- **Reading back what it just wrote.** `write_file` answered only
  `wrote N bytes`, and the model then parsed the new JSON file in a separate
  shell call.
- **Children searching for tools their root loaded.** On the Codex route,
  hosted tool search deferred every MCP tool, including those a child
  inherits (ADR 0227), so each child spent its first call on a tool search.
- **A two-line prompt in a scripted session.** The scripted REPL reads one
  prompt per line, so a task with a line break ran as two turns.
- **`ask_user` with nobody there.** In `-p` and piped sessions the model could
  still ask a question that no one would answer.

## Decision

- Before the first request of a turn, the root loads every deferred tool of a
  connected MCP server that the latest user message names as a whole word,
  if that server's schemas fit in 16 KiB (`mcp_preload.zig`). A larger server
  still waits for an explicit load. A message that asks for subagents loads
  the folded `subagent` and `agent_output` tools the same way. A note tells the
  model what loaded, and for MCP tools repeats what a `load_tool_schemas`
  result says about slimmed result shapes (ADR 0225). Without the shapes, a
  script written against full rows failed on the slimmed ones.
- `write_file` creates a file, or replaces one the session has read, edited
  or written. Replacing any other existing file fails and writes nothing,
  unless the call passes `replace: true`. The result says `created` or
  `replaced` and, for a `.json` path, whether the content parses. The prompt
  says the guard exists, so the model needs no existence check, and that the
  result is the evidence, so it needs no read-back.
- The MCP tools a child inherits are sent with `defer_loading: false`, so
  hosted tool search leaves them callable from the child's first request.
- A piped REPL treats a bracketed paste (`ESC[200~ … ESC[201~`) as one prompt,
  newlines included, which is what a terminal sends for a pasted block.
  Without the frame, each line is still its own prompt.
- `ask_user` is offered only when someone can answer: never under `-p`, and
  never in a piped session outside `--json` or ACP. In those sessions a
  low-effort Codex request also omits reasoning summaries, which only a
  watcher reads and which arrive before the output. The TUI, ACP and
  `--json` keep them.
- With no git identity configured, the model commits with git's defaults
  instead of asking for one.

Two other changes were measured and dropped. Telling the model that a batch
with a write runs its calls in order, so an edit and its check could share a
response, made it split independent edits into separate responses instead.
Accepting `attempt_completion` in the same response as a write saved
nothing, because the model never sent them together. Spelling out how the
slimmed `latest_author` is chosen ("newest by createdAt") made a careful model
read the full results to reconcile it with a task that said "last in the
list".

## Consequences

A model that rewrites a file it has never read, or one created by a shell
command, now spends a call on the refusal or passes `replace: true`. Read
tracking is per process, so a file read by a subagent counts for its root.
Naming a small server, or mentioning subagents, loads those schemas for that
turn even when the message does not mean to use them. Without summaries a
silent low-effort reasoning phase emits no frames; the stall budget covers
it at that effort, and higher efforts keep their summaries.

Revisit the 16 KiB budget if named servers routinely exceed it, the write
guard if refused writes show up in traces more often than the existence
checks they replaced, and the summary rule if a low-effort request ever
stalls before its first frame.
