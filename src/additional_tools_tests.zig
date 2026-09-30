//! Tests for additional_tools.zig (ADR 0221): a load on the ChatGPT plan
//! route must leave `tools` byte-identical and announce the tool in the input.

const std = @import("std");
const additional_tools = @import("additional_tools.zig");
const native_fold = @import("native_fold.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const testAgentFor = @import("agent_request_body_responses.zig").testAgentFor;

/// The body's top-level `tools` array, verbatim: the key right after `input`
/// closes, not an `additional_tools` item's own `tools` inside the input.
fn toolsOf(body: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, body, "],\"tools\":") orelse return "") + "],\"tools\":".len;
    const end = std.mem.indexOfPos(u8, body, start, ",\"tool_choice\"") orelse return "";
    return body[start..end];
}

fn items(messages: []const std.json.Value) usize {
    var n: usize = 0;
    for (messages) |m| if (additional_tools.isItem(m)) {
        n += 1;
    };
    return n;
}

test "ChatGPT plan: a tool load leaves tools byte-identical and adds one additional_tools item" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved_fold = native_fold.enabled;
    const saved_stable = mcp_schema_gate.g_stable_catalog;
    defer {
        native_fold.enabled = saved_fold;
        mcp_schema_gate.g_stable_catalog = saved_stable;
        native_fold.clearLoadedSession();
    }
    native_fold.enabled = true;
    mcp_schema_gate.g_stable_catalog = true;
    native_fold.clearLoadedSession();

    var agent = try testAgentFor(a, "chatgpt-new", .responses, "gpt-6.1-sol");
    agent.invalidateRootTools(); // the test agent starts on the subagent catalog
    try agent.ensureRootTools(.responses);
    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 0), items(agent.messages.items)); // nothing loaded yet
    const before = try agent.buildBody(agent.tools_responses, false, true, true);
    defer std.testing.allocator.free(before);

    // The model loads a folded native; the catalog tail now carries it.
    native_fold.markLoaded("workflow");
    agent.invalidateRootTools();
    try agent.ensureRootTools(.responses);
    try std.testing.expect(std.mem.indexOf(u8, agent.tools_responses, "\"name\":\"workflow\"") != null);

    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 1), items(agent.messages.items));
    const after = try agent.buildBody(agent.tools_responses, false, true, true);
    defer std.testing.allocator.free(after);

    // `tools` is the same bytes before and after the load, without the tail...
    try std.testing.expect(toolsOf(before).len > 2);
    try std.testing.expectEqualStrings(toolsOf(before), toolsOf(after));
    try std.testing.expect(std.mem.indexOf(u8, toolsOf(after), "\"name\":\"workflow\"") == null);
    // ...and the definition arrives as an input item after the prefix.
    try std.testing.expect(std.mem.indexOf(u8, before, "\"type\":\"additional_tools\"") == null);
    const at = std.mem.indexOf(u8, after, "\"type\":\"additional_tools\"") orelse return error.TestExpectedItem;
    try std.testing.expect(at < (std.mem.indexOf(u8, after, "],\"tools\":") orelse return error.TestExpectedTools));
    try std.testing.expect(std.mem.indexOf(u8, after[at..], "\"name\":\"workflow\"") != null);

    // A second sync announces nothing new.
    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 1), items(agent.messages.items));
}

test "ChatGPT plan: a pruned item is announced again; other routes drop the items" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved_fold = native_fold.enabled;
    const saved_stable = mcp_schema_gate.g_stable_catalog;
    defer {
        native_fold.enabled = saved_fold;
        mcp_schema_gate.g_stable_catalog = saved_stable;
        native_fold.clearLoadedSession();
    }
    native_fold.enabled = true;
    mcp_schema_gate.g_stable_catalog = true;
    native_fold.clearLoadedSession();
    native_fold.markLoaded("workflow");

    var agent = try testAgentFor(a, "chatgpt-new", .responses, "gpt-6.1-sol");
    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 1), items(agent.messages.items));

    // Compaction pruned everything before its blob, the item included.
    _ = agent.messages.pop();
    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 1), items(agent.messages.items));

    // Switching to Codex removes the items: there the catalog tail carries the tool.
    agent.provider.id = "codex";
    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 0), items(agent.messages.items));
    agent.invalidateRootTools();
    try agent.ensureRootTools(.responses);
    try std.testing.expect(std.mem.indexOf(u8, agent.tools_responses, "\"name\":\"workflow\"") != null);
    try std.testing.expect(!additional_tools.active("codex", .responses));
    try std.testing.expect(!additional_tools.active("chatgpt-new", .openai));
}
