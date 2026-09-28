//! Runtime-specific addenda for foreign skills whose documented backend is
//! not callable from a standalone graff process. The original skill stays on
//! disk and is still shown after this short, explicit override.

const std = @import("std");

pub const computer_use =
    \\## Graff runtime adapter
    \\
    \\Graff exposes this plugin's authenticated, signed Codex `node_repl` bridge through MCP-qualified tool names. Keep the bootstrap, confirmation policy, fresh-state workflow, and `nodeRepl.emitImage(...)` instructions below unchanged.
    \\
    \\- Where the skill says to use `node_repl`, call `mcp__node_repl__js`; use `mcp__node_repl__js_reset` and `mcp__node_repl__js_add_node_module_dir` for the two companion operations.
    \\- Read-only inspect uses `sky.get_app_state({ app, disableDiff: true })`. Graff advertises MCP form elicitation and accepts that inspect so `nodeRepl.createElicitation` does not fail. Mutating sky input still follows the skill's confirmation policy.
    \\- If form elicitation is still unavailable, do not retry the same call. Ask the user to reconnect MCP (`/mcp trust`), or say what you could not inspect. Do not use the plugin's raw Computer Use MCP client or substitute OS event synthesis: the macOS service authenticates the signed Codex process chain.
;

pub fn prefix(name: []const u8, from_plugin: bool) []const u8 {
    if (from_plugin and std.ascii.eqlIgnoreCase(name, "computer-use")) return computer_use;
    return "";
}

test "only the plugin Computer Use skill receives the signed node_repl adapter" {
    try std.testing.expect(std.mem.indexOf(u8, prefix("computer-use", true), "mcp__node_repl__js") != null);
    try std.testing.expectEqualStrings("", prefix("computer-use", false));
    try std.testing.expectEqualStrings("", prefix("other", true));
}

test "Computer Use adapter names the read-only inspect and the reconnect fallback (#768)" {
    const text = prefix("computer-use", true);
    try std.testing.expect(std.mem.indexOf(u8, text, "disableDiff: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "createElicitation") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/mcp trust") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "desktop `computer`") == null); // removed (ADR 0209)
}
