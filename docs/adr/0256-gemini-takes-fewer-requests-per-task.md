# 0256. Gemini takes fewer requests per task

Status: accepted 2026-10-06

## Context

On the hosted route every Gemini request carries graff's system prompt and
tool catalog again, and each one takes several seconds. A task's wall time and
cost therefore follow its request count far more than its output.

Traces of the core and MCP eval suites showed requests the work did not need:
reading back a file the model had just written or a script had produced, a
separate request for a step that could have chained onto the previous command,
and a last request whose only call was `attempt_completion`. Final answers
also pasted whole files the task had already written to disk.

The harness already accepted `attempt_completion` in the same response as a
read or a check: it ran the check first and withdrew the completion if the
check failed (ADR 0024). The model was never told, and a write in the same
response refused the completion outright. Telling the model through the tool
description alone changed nothing; it batched only when the system prompt
asked it to.

## Decision

For `gemini-` model ids, on any provider:

- The system prompt ends with a short working note: run dependent shell steps
  as one command (writing exact text with `printf`, since `echo -n` under a
  POSIX `sh` prints the flag), treat a write's own result as its evidence, name files
  instead of pasting them into the final answer, call `attempt_completion` in
  the same response as the final check or write, and check a computed answer
  against every condition the task states before writing it.
- `attempt_completion`'s description says the same. A batched `edit_file` or
  `write_file` is held to the rule a check already followed: the batch runs
  first (serially and in the order sent, because it writes) and the
  completion is recorded only if every call succeeded. `rlm`, `subagent` and
  mutating MCP calls still refuse a batched completion.
- Switching between this family and another model rebuilds the root catalog,
  so the description follows the model.

Other models are unchanged. Sub-agents get the note; their catalogs are fixed
at build time and keep the old description.

## Consequences

In interleaved eval rounds on the hosted route the core and MCP suites took
about a third fewer requests and a third less wall time per task, and cost
about a quarter less, with pass rates unchanged; the held-out swe, scatter
and sub-agent suites moved the same way.

A completion batched with a write is recorded without a separate look at the
result. That is what the work note already asked for after a successful
write, and a failed write still withdraws the completion.

Fewer requests also meant fewer second looks. On a count whose naive pattern
also matches a longer token with the same prefix, the model's first command
was wrong in every arm; without the note it looked at the data again and
corrected it, with the first note it wrote the wrong count at once and nearly
always missed. Two lines of that note went: one said to inspect data only
after a step failed, and one treated a command's printed output, not only a
write, as its own evidence. The last line, check a computed answer against
the task's conditions and print what matched, recovered most of those runs for
about one request each. Revisit the note if misses of that kind return, and
the description if another model family shows the same request pattern.
