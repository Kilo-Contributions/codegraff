# 0225. The MCP load result states the slim rule

Status: accepted 2026-09-30

## Context

ADR 0029 slims every large MCP list result in `exec.zig`: rows keep only
`id`/`identifier`/`title`/`name`, and a comment list becomes
`{n, latest_author}`. That applies to rlm binds too. The model was only told
once two shapes were stored for the project (the `# muscle:` line), so in a
fresh project it wrote code for the full rows, failed on the first missing
field, and spent calls finding the real shape before it could finish.

A hill-climb round against a reference harness measured stating the rule on
the load result: cost per task fell on the train and the held-out split, wall
time fell, and pass rate held.

The slim was also lossy: a caller that needed a dropped field (a body, a
state, a label) could not get it back.

## Decision

- `mcp_shapes.annotate` appends the slim rule to every `load_tool_schemas`,
  `mcp_search_tools` and `mcp_select_tool` result, whether or not shapes are
  stored. It never rides the catalog prefix (ADR 0011).
- A direct call's slimmed result keeps the full payload as a tool-result
  handle (`tool_handle.keep`, the #440 store and run budget) and names it, so
  `read_tool_result` reads any dropped field (`mcp_shapes.takeSlimKept`).
- A host call from inside an rlm script (`ToolCtx.rlm_host`) binds the plain
  slim JSON, because `each`, `project` and `write_file` parse it. The rule says
  so: for a dropped field, call the tool directly.

## Consequences

Each MCP load result carries one more sentence, and each slimmed direct result
one more line plus a handle file under `.graff/tool-results/`. When the run's
handle budget is spent, the slim falls back to the plain cut.
