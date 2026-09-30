# 0228. A read-only child calls the MCP tools their server declares read-only

Status: accepted 2026-10-01

## Context

ADR 0227 gives a child the MCP tools its root loaded. A child whose task is
informational runs read-only (#1360), and its gate allowed an MCP call only
for a companion read tool: graff read no MCP tool annotations. A root that
loaded a server's list tools and asked two children to fetch data spawned
children that were classified informational, saw the tools in their catalog,
and had every call refused. They reported the fetch blocked, and the root
gave up instead of writing its result.

The MCP spec lets a server annotate each tool; `readOnlyHint: true` says the
tool does not modify its environment, and absent means it may. Hosted
servers mark their list and get tools this way.

## Decision

- `mcp_pages.appendTools` reads `annotations.readOnlyHint` into
  `mcp.Tool.read_only`; `Registry.declaresReadOnly` answers it by name.
- A read-only child's gate allows an MCP call that is a companion read or a
  tool its server declares read-only. Anything else stays refused.
- A read-only child inherits only the loaded tools its gate lets it call
  (`worker_mcp.withLoaded`), so its catalog never lists a tool it cannot
  use. A child that is not read-only inherits every loaded tool, as before.
- The Linear-shaped eval fixture declares its two list tools read-only, as
  the hosted server it imitates does.

## Consequences

An informational child can fetch through a read tool its root loaded. The
hint is the server's word: a server that marks a writing tool read-only can
write from a read-only child, the same trust the root already extends by
calling it. Plan mode still refuses every MCP call but companion reads;
letting declared reads through there is a separate decision.
