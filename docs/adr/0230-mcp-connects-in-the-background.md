# 0230. MCP connects in the background in every session but `--json`

Status: accepted 2026-10-01. Extends ADR 0035, which covered `--yolo` and
`-p`, to interactive sessions and ACP.

## Context

An interactive session without `--yolo` asked for MCP consent, then waited
for every server's handshake before the prompt was usable: a server that took
five seconds to answer `initialize` held the first message for five seconds.
ACP's `session/new` waited up to three seconds for the servers a client
passed. `--yolo` and `-p` already connected in the background (ADR 0035).

Codex starts every MCP server concurrently in the background, lets a turn go
ahead without a server that is not ready, and reports each server's startup.

## Decision

- `deferMcpJoin`: every session but `--json` connects in the background:
  interactive after consent, `--yolo`, `-p` and ACP. `--json` keeps its
  blocking connect so the protocol stream does not race a late catalog
  merge. The companion auto-connect follows the same gate.
- No model request waits for a handshake. Each request merges the starts
  that have finished (ADR 0035, 0221), and the catalog rebuilds when one
  joined.
- The root request reports what changed: "MCP still connecting — native
  tools this turn" on the first request that goes out while servers connect,
  then "mcp: NAME connected (N tool(s))" or "mcp: NAME did not connect" when
  a start finishes. The registry queues the notices under its lock; the root
  agent's request emits them through the agent's own sink, which is what the
  TUI shows.
- ACP `session/new` and `session/load` wait at most 250 ms for the servers
  the client named: enough for one restored from the tool cache, never a
  real handshake.
- `/mcp` lists without waiting and names the servers still connecting.
  `/mcp add` and `/mcp trust` still join pending starts first.

## Consequences

MCP no longer holds up a session's start. A server that is still connecting
is missing from the first request's tools; they join a later request, as on
`-p` since ADR 0035. The consent prompt still waits for an answer. `--json`
clients still wait; moving them to the background needs startup events in
the protocol.
