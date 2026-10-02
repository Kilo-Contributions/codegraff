# 0236. rlm takes JSON literals, and each() maps plain values

Status: accepted 2026-10-02

## Context

Models write `rlm` scripts the way they write JSON and Python. With thinking
off they did it often enough to cost real time on MCP tasks:

- `ids = ["ISS-1", "ISS-2"]`, `parts = {"ids": ids, "titles": titles}` and
  `write_file("comments.json", [c1, c2])` were refused. Only string, number and
  boolean literals were arguments, and a statement could not bind a literal.
- `each(["ISS-1", "ISS-2"], tool, "id")` was refused as an unsupported
  statement: the splitter nested only parentheses, so the array's commas cut
  it into many arguments.
- `ids = project(issues, "id")` gives a list of plain ids, and
  `each(ids, tool, "id")` failed with `item missing field id`, because each()
  only read fields out of objects. One run repeated that refused call until
  the task ran out of time.
- `each(arr, tool)` with two arguments was refused.
- The refusal said only `unsupported statement`, so the next try was a guess.

## Decision

- A JSON array or object literal is an argument and can be bound:
  `name = [...]`, `name = {...}`, `write_file("r.json", {"ids": ids})`. A bound
  name inside a literal stands for its value: JSON goes in as JSON, other
  text as a JSON string. `True`, `False`, `None` and single-quoted strings are
  read the Python way. `name = "text"`, `name = 3` and `name = other` bind too
  (`rlm_literal.zig`). For `write_file`, the file holds the literal's JSON text.
  A lone object argument is the keyword arguments: `tool({"id": "x"})` is
  `tool(id="x")`. Passed as the first parameter's value instead, the object
  reached an MCP server as a malformed id.
- The statement and argument splitters nest `[...]` and `{...}` as well as
  `(...)`.
- `each(arr, tool[, field])`: `arr` may be a literal; a plain item (a string
  id, a number) is passed as is; `field` picks the value out of object items
  and defaults to an MCP tool's first parameter. A missing field names the
  fields the items do have.
- An unsupported statement lists the forms that work. Nested calls, indexing
  and operators are still refused: `rlm` stays a call-only script.

## Consequences

Scripts that used to fail on a literal now run. A literal holding a name that
was never bound is still refused. The tool description stays inside its
600-byte budget, so the literal forms are spelled out in the `code` argument's
description and in the refusal.

Revisit if traces show models leaning on literals to fake computation that
belongs in the shell.
