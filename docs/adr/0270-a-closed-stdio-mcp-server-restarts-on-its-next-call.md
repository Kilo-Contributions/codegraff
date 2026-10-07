# 0270. A closed stdio MCP server restarts on its next call

Status: accepted 2026-10-07

## Context

When a call to a stdio MCP server failed because its process closed the
connection, graff withdrew every tool the server offered and told the model
to restart the service and the session (#1467). A server that exited once,
for any reason, was gone for the rest of the session even though graff
already knew how to start it: stdio servers with a cached catalog start on
first use (`mcp_lazy.zig`). Issue #1512 asked for recovery without a session
restart.

## Decision

A stdio server keeps the launch config it started from. When a call on it
fails with a closed connection, graff reaps the dead child and returns the
server to dormant with that config; its tools stay advertised. The next call
spawns and handshakes a fresh process exactly as a first use does.

- The call that saw the close is never replayed: it may have run. Its error
  says so and says that state held by the service is gone.
- After two restarts in a session the server is withdrawn as before, so a
  server that dies on every call stops costing turns.
- HTTP servers, and stdio servers without a launch config, are withdrawn as
  before.

## Consequences

One crash no longer removes a service for the rest of the session, and the
catalog does not change, so the provider prefix cache survives it. A restarted
server loses whatever it held (open pages, sessions, caches); the error text
tells the model. `mcp_restart.zig` owns the rule and its regression test.
