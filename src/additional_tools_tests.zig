//! Tests for additional_tools.zig (ADR 0221): a load on the ChatGPT plan
//! route or on MiMo's or DeepSeek's chat wire must leave `tools`
//! byte-identical and announce the tool in the conversation instead.

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
    try std.testing.expect(!additional_tools.active(agent.provider));
    var chat = agent.provider;
    chat.id = "chatgpt-new";
    chat.kind = .openai;
    try std.testing.expect(!additional_tools.active(chat));
}

/// A chat body's top-level `tools`: it precedes `messages`, where the
/// announcement's own escaped definitions live.
fn chatToolsOf(body: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, body, "\"tools\":") orelse return "") + "\"tools\":".len;
    const end = std.mem.indexOfPos(u8, body, start, ",\"messages\":") orelse return "";
    return body[start..end];
}

test "MiMo chat: a tool load leaves tools byte-identical and adds one system announcement" {
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

    var agent = try testAgentFor(a, "codegraff", .openai, "mimo-v2.6-pro");
    try std.testing.expect(additional_tools.active(agent.provider));
    agent.invalidateRootTools();
    try agent.ensureRootTools(.openai);
    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 0), items(agent.messages.items));
    const before = try agent.buildBody(agent.tools_openai, false, true, true);
    defer std.testing.allocator.free(before);

    native_fold.markLoaded("workflow");
    agent.invalidateRootTools();
    try agent.ensureRootTools(.openai);
    try std.testing.expect(std.mem.indexOf(u8, agent.tools_openai, "\"name\":\"workflow\"") != null);
    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 1), items(agent.messages.items));
    const note = agent.messages.items[agent.messages.items.len - 1].object;
    try std.testing.expectEqualStrings("system", note.get("role").?.string);
    try std.testing.expect(std.mem.indexOf(u8, note.get("content").?.string, "\"name\":\"workflow\"") != null);
    const after = try agent.buildBody(agent.tools_openai, false, true, true);
    defer std.testing.allocator.free(after);

    try std.testing.expect(chatToolsOf(before).len > 2);
    try std.testing.expectEqualStrings(chatToolsOf(before), chatToolsOf(after));
    try std.testing.expect(std.mem.indexOf(u8, chatToolsOf(after), "\"name\":\"workflow\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "_graff_origin") == null); // the tag never reaches the wire

    // Announced once; a pruned announcement comes back; another chat model drops it.
    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 1), items(agent.messages.items));
    _ = agent.messages.pop();
    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 1), items(agent.messages.items));
    agent.provider.model = "glm-5.3";
    additional_tools.sync(&agent);
    try std.testing.expectEqual(@as(usize, 0), items(agent.messages.items));
}

test "DeepSeek and Claude chat: a tool load leaves tools byte-identical and adds one user announcement that is not a prompt" {
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

    // Claude keeps its tail in `tools` on its own API and elsewhere until each is checked.
    try std.testing.expect(!additional_tools.active((try testAgentFor(a, "anthropic", .anthropic, "claude-sonnet-5-5")).provider));
    try std.testing.expect(!additional_tools.active((try testAgentFor(a, "openrouter", .openai, "anthropic/claude-sonnet-5.5")).provider));

    // DeepSeek's own API and the gateway, Pro and Flash, and Claude on the gateway.
    for ([_][2][]const u8{ .{ "deepseek", "deepseek-v4-pro" }, .{ "codegraff", "deepseek-v4-flash" }, .{ "codegraff", "claude-sonnet-5-5" } }) |route| {
        native_fold.clearLoadedSession();
        var agent = try testAgentFor(a, route[0], .openai, route[1]);
        try std.testing.expect(additional_tools.active(agent.provider));
        agent.invalidateRootTools();
        try agent.ensureRootTools(.openai);
        const before = try agent.buildBody(agent.tools_openai, false, true, true);
        defer std.testing.allocator.free(before);

        native_fold.markLoaded("workflow");
        agent.invalidateRootTools();
        try agent.ensureRootTools(.openai);
        additional_tools.sync(&agent);
        try std.testing.expectEqual(@as(usize, 1), items(agent.messages.items));
        const note = agent.messages.items[agent.messages.items.len - 1];
        // User-role: on V4 Pro and the Claude route a system message would re-bill the conversation.
        try std.testing.expectEqualStrings("user", note.object.get("role").?.string);
        try std.testing.expect(std.mem.indexOf(u8, note.object.get("content").?.string, "\"name\":\"workflow\"") != null);
        // Harness text, not something the human typed.
        try std.testing.expect(@import("messages.zig").userPromptText(note) == null);
        try std.testing.expect(@import("session_wake.zig").isNotice(note));
        const after = try agent.buildBody(agent.tools_openai, false, true, true);
        defer std.testing.allocator.free(after);

        try std.testing.expect(chatToolsOf(before).len > 2);
        try std.testing.expectEqualStrings(chatToolsOf(before), chatToolsOf(after));
        try std.testing.expect(std.mem.indexOf(u8, after, "_graff_origin") == null);

        // A switch to another wire drops the announcement rather than carrying it as text.
        var msgs = agent.messages;
        @import("history_translate.zig").translateHistory(a, &msgs, .anthropic);
        try std.testing.expectEqual(@as(usize, 0), items(msgs.items));
        for (msgs.items) |m| try std.testing.expect(std.mem.indexOf(u8, try std.json.Stringify.valueAlloc(a, m, .{}), "workflow") == null);
    }
}

test "Claude chat: a direct call's load reaches the catalog, so its string arguments get their types" {
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

    var agent = try testAgentFor(a, "codegraff", .openai, "claude-sonnet-5-5");
    agent.invalidateRootTools();
    try agent.ensureRootTools(.openai);
    try std.testing.expect(!additional_tools.staleCatalog(&agent));

    // The model calls agent_output without loading it: the call loads it, the catalog is not rebuilt.
    try std.testing.expect(native_fold.gateExec(a, "agent_output", false) == null);
    try std.testing.expect(additional_tools.staleCatalog(&agent));
    agent.invalidateRootTools();
    try agent.ensureRootTools(.openai);
    try std.testing.expect(!additional_tools.staleCatalog(&agent));

    // Claude sent an undeclared tool's values as strings; the rebuilt catalog types them.
    var message = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"agent_output","arguments":"{\"id\": \"1\", \"wait_ms\": \"300000\"}"}}]}
    , .{});
    try std.testing.expect(try @import("tool_call_repair.zig").retypeArgs(a, a, &message, agent.toolsJson()));
    const text = message.object.get("tool_calls").?.array.items[0].object.get("function").?.object.get("arguments").?.string;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    try std.testing.expectEqual(@as(i64, 1), args.object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 300000), args.object.get("wait_ms").?.integer);
}
