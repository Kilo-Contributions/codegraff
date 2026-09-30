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

## Decision

`mcp_shapes.annotate` appends the slim rule to every `load_tool_schemas`,
`mcp_search_tools` and `mcp_select_tool` result, whether or not shapes are
stored. It never rides the catalog prefix (ADR 0011).

## Consequences

Each MCP load result carries one more sentence. The slim itself is unchanged:
a caller that needs a dropped field still cannot get it, which is a separate
decision about ADR 0029.
