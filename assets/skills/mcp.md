---
name: mcp
description: Add, connect, or invoke an MCP server in this workspace — use when the user says "using the MCP skill", asks to add/connect/enable/turn on an MCP, pastes an MCP URL or npx package, or wants DeepWiki/Mobbin tools this session.
---

# Add and invoke an MCP server

This is the invocative half. `mcp-config` is the schema reference; load it
only when you need field-level detail. Do the add here.

## Choreography

1. Pass what the user gave you straight to `graff mcp add`. It infers the
   name and transport, saves to the **project** `.mcp.json`, then connects
   and lists the tools:

```sh
graff mcp add linear                                # a name → codegraff.com/mcp, then the MCP registry
graff mcp add https://mcp.deepwiki.com/mcp          # URL → HTTP, named "deepwiki"
graff mcp add @playwright/mcp                       # npm package → npx -y
graff mcp add uvx:mcp-server-fetch                  # Python package → uvx
graff mcp add '{"mcpServers":{...}}'                # a pasted Claude/Cursor/VS Code block
graff mcp add <name> --env KEY=VALUE -- <command> [args...]
```

   A name is looked up in the list at codegraff.com/mcp, then in the official
   MCP registry, where graff only picks a publisher that owns the name. If it
   lists registry candidates instead, show them to the user; do not pick one.
   `--name <name>` overrides the inferred name. Add `--everywhere` only
   when the user wants it in every project (it writes ~/.codegraff/mcp.json).
   On a device enrolled with `graff keys enable`, that file also syncs to the
   user's other devices (`graff mcp sync` forces it now). Do not put secrets in the chat.

2. Read the result line:
   - `✓ <name> works: N tool(s) — …`: done.
   - `needs sign-in: run graff mcp login <name>`: ask the user to run it
     (it opens a browser; you cannot finish it for them).
   - `<server> needs KEY: …` / `nothing was saved`: ask the user for that key
     or token, then re-run with the `--env KEY=…` / `--header "K=…"` it shows.
   - `✗ saved <name>, but it did not connect (…): <hint>`: follow the hint
     (install Node or uv, add `--env`, fix the package name), then re-run
     the same `graff mcp add`.

3. Use it. When this session already connected its configured servers, a new
   entry joins before your next request with no restart. Call
   `load_tool_schemas` with `server` set to the name (or the exact
   `mcp__<server>__<tool>` names) before calling anything. If startup consent
   was declined, the user runs `/mcp trust` first.

## DeepWiki and Mobbin

When configured, boot skips a `deepwiki` / `mobbin` entry inherited from
global or plugin configuration unless `GRAFF_DEEPWIKI` / `GRAFF_MOBBIN`
is set, or `GRAFF_MCP_OPTIONAL=deepwiki,mobbin`.
A workspace `.mcp.json` that lists them is the project opting in. Startup
consent (`/mcp trust` or `--yolo`) still applies.

DeepWiki's public server is `https://mcp.deepwiki.com/mcp` (no auth). Tools
are `read_wiki_structure`, `read_wiki_contents`, and `ask_question`. Do not
webfetch DeepWiki pages; use those tools once loaded.

## Examples

User: "using the MCP skill, add this MCP: https://mcp.deepwiki.com/mcp"

- `graff mcp add https://mcp.deepwiki.com/mcp`
- `load_tool_schemas` with `server=deepwiki`, then use it.

User: "add playwright MCP"

- `graff mcp add playwright`
