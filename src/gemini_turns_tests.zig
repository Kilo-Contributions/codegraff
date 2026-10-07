//! ADR 0256 regressions: the Gemini working note, the batched-completion
//! description, and the write rule follow the model, including across a
//! same-wire model switch.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const ToolCall = @import("tools.zig").ToolCall;
const providers = @import("providers.zig");
const gemini = @import("gemini_turns.zig");
const eval_control = @import("agent_eval_control.zig");

fn call(arena: std.mem.Allocator, name: []const u8) !ToolCall {
    return .{ .id = name, .name = name, .input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{}) };
}

test "a write may share a response with attempt_completion only where writes complete" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const done = try call(a, "attempt_completion");
    for ([_][]const u8{ "edit_file", "write_file" }) |name| {
        const write = try call(a, name);
        for ([_][2]ToolCall{ .{ write, done }, .{ done, write } }) |batch| {
            try std.testing.expect(eval_control.batchBlocksCompletionFor(&batch, false));
            try std.testing.expect(!eval_control.shouldDeferCompletionFor(&batch, false));
            try std.testing.expect(!eval_control.batchBlocksCompletionFor(&batch, true));
            try std.testing.expect(eval_control.shouldDeferCompletionFor(&batch, true));
        }
        const check = try call(a, "shell");
        const with_check = [_]ToolCall{ write, check, done };
        try std.testing.expect(eval_control.shouldDeferCompletionFor(&with_check, true));
    }
    // Calls that change more than a named file still refuse a batched completion.
    for ([_][]const u8{ "rlm", "subagent", "mcp__codedbpro__edit" }) |name| {
        const mutation = [_]ToolCall{ try call(a, "write_file"), try call(a, name), done };
        try std.testing.expect(eval_control.batchBlocksCompletionFor(&mutation, true));
        try std.testing.expect(!eval_control.shouldDeferCompletionFor(&mutation, true));
    }
    // The defaults are the old rule.
    const old = [_]ToolCall{ try call(a, "edit_file"), done };
    try std.testing.expect(eval_control.batchBlocksCompletion(&old));
    try std.testing.expect(!eval_control.shouldDeferCompletion(&old));
}

fn promptAgent(arena: std.mem.Allocator, id: []const u8, kind: Provider.Kind, model: []const u8) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = id, .kind = kind, .auth = .bearer, .url = "", .api_key = "", .model = model, .context = 1_000_000 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "BASE",
    };
}

test "the working note rides only on Gemini models, on any route" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const compose = @import("agent_request_body_responses.zig").schemaAwarePrompt;
    const routes = [_]struct { id: []const u8, kind: Provider.Kind, model: []const u8 }{
        .{ .id = "codegraff", .kind = .openai, .model = "gemini-3.8-flash" },
        .{ .id = "google", .kind = .interactions, .model = "gemini-3.7-flash" },
    };
    for (routes) |r| {
        var agent = promptAgent(a, r.id, r.kind, r.model);
        const prompt = try compose(&agent);
        try std.testing.expect(std.mem.startsWith(u8, prompt, "BASE\n"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, prompt, "# Working guidance"));
        agent.sub = true; // children carry it too: they pay the same per request
        try std.testing.expect(std.mem.indexOf(u8, try compose(&agent), "# Working guidance") != null);
    }
    for ([_][]const u8{ "gpt-5.6", "deepseek-v4-flash", "mimo-v2.6-flash", "gemma-3" }) |model| {
        var agent = promptAgent(a, "codegraff", .openai, model);
        try std.testing.expect(std.mem.indexOf(u8, try compose(&agent), "# Working guidance") == null);
    }
}

test "attempt_completion's description follows a same-wire model switch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const deepseek: Provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "deepseek-v4-flash", .context = 1_000_000 };
    var flash = deepseek;
    flash.model = "gemini-3.8-flash";

    var root: Agent = undefined;
    root.provider = deepseek;
    root.io = std.testing.io;
    root.jev_effort_pending = .{};
    root.subagent_provider = null;
    root.subagent_provider_explicit = true;
    root.arena = a;
    root.registry = null;
    root.messages = std.json.Array.init(a);
    root.sub = false;
    root.strict = false;
    root.sys_normal = "";
    root.sys_strict = "";
    root.tools_anthropic = "";
    root.tools_openai = "";
    root.tools_responses = "";
    root.tools_interactions = "";
    root.keep_context = true;
    root.last_context_tokens = 0;
    root.context_local_tokens = 0;
    root.last_cache_read = 0;
    root.cap_new = false;
    root.sox_json_object = false;
    root.effort_rejected = false;
    root.ws_off = false;
    root.ws_transport_failures = 0;

    try root.ensureRootTools(.openai);
    try std.testing.expect(std.mem.indexOf(u8, root.tools_openai, gemini.completion_batch) == null);
    _ = try providers.applyProviderInner(&root, a, flash, false);
    try std.testing.expect(std.mem.indexOf(u8, root.tools_openai, gemini.completion_batch) != null);
    try std.testing.expect(std.json.validate(a, root.tools_openai) catch false);
    _ = try providers.applyProviderInner(&root, a, deepseek, false);
    try std.testing.expect(std.mem.indexOf(u8, root.tools_openai, gemini.completion_batch) == null);
}
