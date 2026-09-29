//! #1284: OpenRouter chat completions carried no cache hints, so Anthropic
//! models routed there paid full input price every turn. OpenRouter documents
//! two fields for it: a top-level `cache_control` that puts the breakpoint on
//! the last cacheable block (Anthropic models; the others cache on their own),
//! and `session_id`, the sticky-routing key that sends later requests to the
//! provider endpoint holding the prefix. Its usage already reports
//! `prompt_tokens_details.cached_tokens` and `cache_write_tokens`, which
//! agent_context reads, so hits show up in cost and the `usage` trace.

const std = @import("std");
const Agent = @import("agent.zig").Agent;

pub fn write(s: anytype, provider_id: []const u8, model: []const u8, session_key: []const u8, cache_control: []const u8) !void {
    if (!std.mem.eql(u8, provider_id, "openrouter")) return;
    try s.objectField("session_id");
    try s.write(session_key);
    if (!std.mem.startsWith(u8, model, "anthropic/")) return;
    try s.objectField("cache_control");
    try s.print("{s}", .{cache_control});
}

fn body(arena: std.mem.Allocator, provider_id: []const u8, model: []const u8) ![]u8 {
    var messages = std.json.Array.init(arena);
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .string = "hello" });
    try messages.append(.{ .object = user });
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = provider_id, .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = model, .context = 200_000 },
        .messages = messages,
        .sub = false,
        .label = "main",
        .out = null,
        .sys_normal = "system",
    };
    const built = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(built);
    return arena.dupe(u8, built);
}

test "#1284: OpenRouter requests pin a session; Anthropic models there get a cache breakpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const claude = try body(arena, "openrouter", "anthropic/claude-sonnet-5");
    try std.testing.expect(std.mem.indexOf(u8, claude, "\"session_id\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    const other = try body(arena, "openrouter", "deepseek/deepseek-v4-pro");
    try std.testing.expect(std.mem.indexOf(u8, other, "\"session_id\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, other, "cache_control") == null); // caches on its own
    const direct = try body(arena, "openai", "gpt-5.6");
    try std.testing.expect(std.mem.indexOf(u8, direct, "session_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, direct, "cache_control") == null);
}
