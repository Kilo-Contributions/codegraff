# 0254. Imported conversations use the configured route

Status: accepted 2026-10-04

## Context

An imported transcript records the source model, but restoring that route would
require unrelated credentials and override the user's configured agent.

## Decision

Claude transcript imports carry `imported_from: "claude"`. Their first load keeps
the configured graff provider and credentials. Source model fields are historical
metadata; import never launches or authenticates the source runtime.

When the wire format changes, historical tool calls and results become labeled
text receipts. Ordinary graff saves retain their existing route-restoration rule.
After continuation, the imported session is saved as an ordinary graff session.

## Evidence

[Import regression tests](../../src/adopt_sessions_tests.zig) cover empty source
credentials and retained tool results across request formats. The
`claude-conversation-import-resume` behavior case checks the model request.
