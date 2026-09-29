//! #1320: an Anthropic cache entry lives 5 minutes from its last use. A model
//! call that runs longer (slow reasoning at a large context) comes back to an
//! expired prefix, and the next request reads nothing. When this agent's
//! previous request began 3+ minutes ago, calls are that slow: its successor
//! asks for the 1-hour TTL (a 2x write instead of 1.25x, on the tokens it
//! writes) so the entry outlives the next slow call. The gap is taken once
//! per request, before any retry, and usage_trace.zig reports it with the
//! reason a request read nothing.

const std = @import("std");
const Agent = @import("agent.zig").Agent;

pub const ephemeral = "{\"type\":\"ephemeral\"}";
pub const ephemeral_1h = "{\"type\":\"ephemeral\",\"ttl\":\"1h\"}";
/// A previous request this long ago means calls outlive a 5-minute entry.
pub const slow_gap_ms: i64 = 3 * 60 * 1000;
/// The provider's default entry lifetime (Anthropic's; others are similar).
pub const default_ttl_ms: i64 = 5 * 60 * 1000;

/// Requests and their usage lines run on one thread (see usage_trace.zig).
threadlocal var gap_ms: ?i64 = null;

/// Before a request's retry loop: time since this agent's previous request began.
pub fn begin(self: *const Agent) void {
    gap_ms = if (self.request_started) |t| t.untilNow(self.io, .awake).toMilliseconds() else null;
}

pub fn gap() ?i64 {
    return gap_ms;
}

/// The Anthropic API, and Anthropic models through OpenRouter (#1284), take a
/// TTL; other Anthropic-format providers keep the default.
pub fn takesTtl(provider_id: []const u8, model: []const u8) bool {
    return std.mem.eql(u8, provider_id, "anthropic") or
        (std.mem.eql(u8, provider_id, "openrouter") and std.mem.startsWith(u8, model, "anthropic/"));
}

pub fn longTtl(provider_id: []const u8, model: []const u8, since_previous: ?i64) bool {
    const g = since_previous orelse return false;
    return takesTtl(provider_id, model) and g >= slow_gap_ms;
}

/// The cache_control object for this request's breakpoints.
pub fn control(self: *const Agent) []const u8 {
    return if (longTtl(self.provider.id, self.provider.model, gap_ms)) ephemeral_1h else ephemeral;
}

/// Why a request with real input read nothing from the cache. Content-free.
pub fn missReason(cache_read: i64, input: i64, prefix_changed: bool, since_previous: ?i64) ?[]const u8 {
    if (cache_read > 0 or input < 1024) return null;
    if (prefix_changed) return "prefix_changed";
    const g = since_previous orelse return "first_request";
    return if (g >= default_ttl_ms) "idle_gap" else "unknown";
}

test "#1320: slow calls get the 1-hour TTL on the Anthropic API only" {
    try std.testing.expect(!longTtl("anthropic", "claude-opus-5", null));
    try std.testing.expect(!longTtl("anthropic", "claude-opus-5", 90_000));
    try std.testing.expect(longTtl("anthropic", "claude-opus-5", 307_000));
    try std.testing.expect(!longTtl("kimi", "k3", 307_000));
    try std.testing.expect(!longTtl("codex", "gpt-6-sol", 307_000));
    // #1284: Anthropic models through OpenRouter take the TTL too.
    try std.testing.expect(longTtl("openrouter", "anthropic/claude-sonnet-5", 307_000));
    try std.testing.expect(!longTtl("openrouter", "deepseek/deepseek-v4-pro", 307_000));
}

test "#1320: an Anthropic body after a slow call marks every breakpoint 1h; Kimi keeps the default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
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
        .provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude-fixture", .context = 200_000 },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
    defer gap_ms = null;
    const long = "\"cache_control\":" ++ ephemeral_1h;
    gap_ms = 307_000;
    const slow = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(slow);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, slow, long)); // system + last message
    try std.testing.expect(std.mem.indexOf(u8, slow, "\"cache_control\":" ++ ephemeral ++ "") == null);
    gap_ms = 20_000;
    const fast = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(fast);
    try std.testing.expect(std.mem.indexOf(u8, fast, "\"ttl\"") == null);
    agent.provider.id = "kimi";
    gap_ms = 307_000;
    const kimi = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(kimi);
    try std.testing.expect(std.mem.indexOf(u8, kimi, "\"ttl\"") == null);
}

test "#1320: a zero-read request names its likely cause" {
    try std.testing.expect(missReason(900, 1000, true, 1) == null);
    try std.testing.expect(missReason(0, 200, false, null) == null); // below any cacheable size
    try std.testing.expectEqualStrings("prefix_changed", missReason(0, 90_000, true, 400_000).?);
    try std.testing.expectEqualStrings("first_request", missReason(0, 90_000, false, null).?);
    try std.testing.expectEqualStrings("idle_gap", missReason(0, 90_000, false, 307_000).?);
    try std.testing.expectEqualStrings("unknown", missReason(0, 90_000, false, 20_000).?);
}

test {
    _ = @import("openrouter_cache.zig");
}
