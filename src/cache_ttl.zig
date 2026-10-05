//! #1320: an Anthropic cache entry lives 5 minutes from its last use. A model
//! call that runs longer (slow reasoning at a large context) comes back to an
//! expired prefix, and the next request reads nothing. When this agent's
//! previous request began 3+ minutes ago, calls are that slow: its successor
//! asks for the 1-hour TTL (a 2x write instead of 1.25x, on the tokens it
//! writes) so the entry outlives the next slow call. The gap is taken once
//! per request, before any retry, and usage_trace.zig reports it with the
//! reason a request read nothing.
//!
//! ADR 0220: the request that opens a user turn waited on the user, not on
//! the model. Its gap says nothing about how long the next call takes, and
//! after an idle past 5 minutes it rewrites the whole prefix: at 1 hour that
//! rewrite cost 2x instead of 1.25x. It follows the last gap measured inside
//! a turn instead.

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
/// The gap the TTL follows: the last one measured inside a turn.
threadlocal var loop_gap_ms: ?i64 = null;

/// Before a request's retry loop: time since this agent's previous request began.
pub fn begin(self: *const Agent) void {
    gap_ms = if (self.request_started) |t| t.untilNow(self.io, .awake).toMilliseconds() else null;
    if (self.request_started == null) {
        loop_gap_ms = null; // a fresh agent on this thread
    } else if (!opensTurn(self.messages.items)) loop_gap_ms = gap_ms;
}

pub fn gap() ?i64 {
    return gap_ms;
}

/// The request answers a new user message (or a wake), not a tool result.
fn opensTurn(items: []const std.json.Value) bool {
    return items.len > 0 and @import("compact_cut.zig").cleanUserTurn(items[items.len - 1]);
}

/// The Anthropic API, and Anthropic models through OpenRouter (#1284), take a
/// TTL; other Anthropic-format providers keep the default.
pub fn takesTtl(provider_id: []const u8, model: []const u8) bool {
    return @import("claude_wire.zig").isClaudeApi(provider_id, model) or
        (std.mem.eql(u8, provider_id, "openrouter") and std.mem.startsWith(u8, model, "anthropic/"));
}

pub fn longTtl(provider_id: []const u8, model: []const u8, since_previous: ?i64) bool {
    const g = since_previous orelse return false;
    return takesTtl(provider_id, model) and g >= slow_gap_ms;
}

/// Whether this thread's current request asks for the 1-hour TTL.
pub fn asksLong(provider_id: []const u8, model: []const u8) bool {
    return longTtl(provider_id, model, loop_gap_ms);
}

/// The cache_control object for this request's breakpoints. Null on a
/// compaction request that does not fork the conversation (ADR 0220): no
/// later request starts with its bytes, so a write would never be read.
pub fn control(self: *const Agent) ?[]const u8 {
    if (self.compaction_request and !@import("cache_fork.zig").shares()) return null;
    return if (asksLong(self.provider.id, self.provider.model)) ephemeral_1h else ephemeral;
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
    defer loop_gap_ms = null;
    const long = "\"cache_control\":" ++ ephemeral_1h;
    loop_gap_ms = 307_000;
    const slow = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(slow);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, slow, long)); // system + last message
    try std.testing.expect(std.mem.indexOf(u8, slow, "\"cache_control\":" ++ ephemeral ++ "") == null);
    loop_gap_ms = 20_000;
    const fast = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(fast);
    try std.testing.expect(std.mem.indexOf(u8, fast, "\"ttl\"") == null);
    // ADR 0220: a compaction request outside a fork carries no breakpoint.
    agent.compaction_request = true;
    const summary = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "cache_control") == null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"system\":[{\"type\":\"text\",\"text\":\"system\"}]") != null);
    agent.compaction_request = false;
    agent.provider.id = "kimi";
    loop_gap_ms = 307_000;
    const kimi = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(kimi);
    try std.testing.expect(std.mem.indexOf(u8, kimi, "\"ttl\"") == null);
}

test "ADR 0220: the request that opens a turn keeps the TTL of the last gap inside one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prompt: std.json.ObjectMap = .empty;
    try prompt.put(arena, "role", .{ .string = "user" });
    try prompt.put(arena, "content", .{ .string = "next task" });
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "type", .{ .string = "tool_result" });
    var blocks = std.json.Array.init(arena);
    try blocks.append(.{ .object = result });
    var results: std.json.ObjectMap = .empty;
    try results.put(arena, "role", .{ .string = "user" });
    try results.put(arena, "content", .{ .array = blocks });
    var in_turn = std.json.Array.init(arena);
    try in_turn.append(.{ .object = results });
    var opening = std.json.Array.init(arena);
    try opening.append(.{ .object = prompt });
    defer loop_gap_ms = null;

    var agent: Agent = undefined;
    agent.io = std.testing.io;
    agent.request_started = null;
    loop_gap_ms = 307_000;
    begin(&agent); // a fresh agent on this thread starts clean
    try std.testing.expect(loop_gap_ms == null);

    // Inside a turn the TTL follows the measured gap.
    agent.request_started = std.Io.Timestamp.now(std.testing.io, .awake);
    agent.messages = in_turn;
    begin(&agent);
    try std.testing.expect(loop_gap_ms.? < 60_000);
    try std.testing.expect(!asksLong("anthropic", "claude-opus-5-5"));

    // A turn-opening request keeps the last in-turn gap, not its own: a slow
    // model stays on the hour, and an idle user never buys one.
    loop_gap_ms = 307_000;
    agent.messages = opening;
    begin(&agent);
    try std.testing.expectEqual(@as(i64, 307_000), loop_gap_ms.?);
    try std.testing.expect(asksLong("anthropic", "claude-opus-5-5"));
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

test "codegraff Claude takes the TTL like the direct Anthropic API" {
    try std.testing.expect(takesTtl("codegraff", "claude-opus-5-5"));
    try std.testing.expect(takesTtl("codegraff", "claude-sonnet-5-5"));
    try std.testing.expect(!takesTtl("codegraff", "gpt-6-sol"));
    try std.testing.expect(!takesTtl("codegraff", "mimo-v2.6-pro"));
}
