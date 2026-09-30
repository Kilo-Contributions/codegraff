# 0227. Children inherit the MCP tools their root loaded

Status: accepted 2026-10-01

## Context

A child is served a fixed, comptime-baked catalog (`schema.subToolsJson`)
with no MCP tools and no load tool. A root that loaded a server's tools and
delegated work on them spawned children that could not call them. Each child
reported the tools missing, and the root either did the work itself or
re-spawned children that spoke the server's JSON-RPC by hand through a
shell. On a task that splits MCP calls across two children, that was the
largest wall-time gap against a reference harness.

A child's provider slots (`tools_anthropic`, `tools_responses`, ...) default
to the static catalogs, so `agent_catalog.ensureRootTools` returns before it
builds anything for a child. A per-child catalog cannot hang off an empty
slot.

## Decision

- `worker_mcp.inherit` runs once as `subagent_run` builds a child, a resumed
  worker included. Whatever catalog the child would be served gains an entry,
  with its full schema, for each MCP tool the root has loaded
  (`mcp_schema_gate.isLoaded`). The result lives in `Agent.worker_tools`,
  which `toolsJson` serves first.
- Tools the root has not loaded stay out, and a child still has no load tool.
- A child's request keeps every tool it lists: the `additional_tools`
  announcement path (ADR 0221) is root-only.

## Consequences

A child can call what its root loaded, so split MCP work runs in parallel
instead of serially in the root. Each child request carries those schemas;
a child's catalog is fixed for its run, so its prompt cache holds. A
write-capable tool the root loaded reaches its children too, under the same
approvals. The licensed worker catalog in `ensureRootTools` hits the same
default slots and still never builds for a child; turning it on needs its
own change, because that render also drops the folded natives a child
cannot load.
