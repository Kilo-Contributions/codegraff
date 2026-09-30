# 0224. Six rarely used natives join the fold

Status: accepted 2026-09-30

## Context

`native_fold.folded` keeps late-use natives out of the eager root catalog:
their names ride the `load_tool_schemas` listing and a confident call loads
the schema on the spot. Six natives stayed eager although a root turn loop
seldom calls them: `render_html`, `agent_message`, `install_agent_tool`,
`read_tool_result`, `subagent_resume` and `schedule_task`. Their schemas
were paid on every request, and cold on every first request.

A hill-climb round against a reference harness measured folding them: cost
per task fell on the train and the held-out split with pass rate held, and a
confirmation round with the arms in the opposite order agreed.

## Decision

Add the six names to `native_fold.folded`. They stay advertised (the
tool-catalog kernel is unchanged) and callable: the listing names them, and
the auto-load path runs a confident call without a refuse-load-retry round
trip. `read_tool_result` needs no schema to be called right: the spill
marker spells out `read_tool_result(handle, offset, limit)`.

## Consequences

The eager root catalog is smaller on every provider. A session that does
use one of these tools pays one schema load, once. Subagents are unaffected;
their catalogs are comptime-baked full surfaces. `GRAFF_NO_NATIVE_FOLD`
still restores every schema.
