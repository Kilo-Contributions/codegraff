# 0240. A slim view names its fields, one script fetches and computes, and an unbound call prints

Status: accepted 2026-10-03

## Context

ADR 0238 made rlm binds keep the whole MCP result and `print()` show the slim
view. Paired eval runs against a code-mode harness on the same models and
tasks still showed rlm scripts spending calls the task did not need:

- A slim view kept only identity fields and said nothing about the rest, so
  the model printed a sample row, or called `read_tool_result`, just to learn
  which fields existed before it could `project()` one.
- The slim rule said a bind keeps every field, but not where to compute over
  it. Models fetched in one rlm call and computed in a second, paying a whole
  model call to carry a value from one script to the next.
- A bare host call (`read_file("x")`, `each(ids, get_issue)`) with no name to
  bind ran and printed nothing, so the model repeated it with `print()`.

## Decision

- A slim view names the fields of the whole value: the first row's keys
  (or, for an `each()` bind, the first item's first row), capped at 24 names.
  Both the rlm print marker and a direct call's handle marker carry
  `; fields: ...`.
- The slim rule, stated on every MCP load result (ADR 0225), adds: to compute
  over results in the same call, save them and run the computation inside the
  script, with a one-line example (`write_file` then a shell heredoc).
- An rlm statement that calls a host tool, or `each()`, without binding a
  name prints its result (slimmed as `print()` would).

## Consequences

Slim markers are a few dozen bytes longer. A script line that only called a
tool for its side effect now also prints that tool's result. Revisit if traces
show field lists crowding out useful output, or models writing bare calls they
meant as silent side effects.
