//! ADR 0220: on the Anthropic API a 1-hour cache write costs 2x input and a
//! 5-minute one 1.25x. The tally prices every write at 1.25x
//! (pricing_cache.usdForUsage), so a session that asked for the 1-hour TTL
//! (cache_ttl.zig, #1320) reported less than it was billed. The response's
//! usage.cache_creation splits the written tokens by TTL; the 1-hour part's
//! difference is added to the session's cost here.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const pricing = @import("pricing.zig");
const pricing_cache = @import("pricing_cache.zig");
const billing = @import("billing.zig");

/// Tokens this response wrote to the 1-hour cache.
pub fn hourTokens(usage: std.json.ObjectMap) i64 {
    const split = usage.get("cache_creation") orelse return 0;
    if (split != .object) return 0;
    const v = split.object.get("ephemeral_1h_input_tokens") orelse return 0;
    return if (v == .integer and v.integer > 0) v.integer else 0;
}

/// One Anthropic response's usage into the session tally, 1-hour writes at 2x.
pub fn record(self: *Agent, usage: std.json.ObjectMap, ordinary: i64, cache_read: i64, cache_write: i64, out: i64) void {
    self.recordCost(ordinary, cache_read, cache_write, out);
    const hour = hourTokens(usage);
    if (hour == 0 or billing.forProvider(self.provider) != .priced) return;
    const p = pricing.priceForProvider(self.provider.id, self.provider.model) orelse return;
    const prompt: u64 = @intCast(@max(ordinary, 0) +| @max(cache_read, 0) +| @max(cache_write, 0));
    const extra = pricing_cache.hourWriteExtraUsd(p, self.provider.model, prompt, hour);
    if (extra == 0) return;
    pricing.g_cost.mutex.lockUncancelable(self.io);
    defer pricing.g_cost.mutex.unlock(self.io);
    pricing.g_cost.usd += extra;
}

test "ADR 0220: usage.cache_creation names the 1-hour writes" {
    const gpa = std.testing.allocator;
    const body =
        \\{"input_tokens":10,"cache_creation_input_tokens":300,"cache_read_input_tokens":5000,
        \\ "cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 200), hourTokens(parsed.value.object));
    var bare = try std.json.parseFromSlice(std.json.Value, gpa, "{\"cache_creation_input_tokens\":300}", .{});
    defer bare.deinit();
    try std.testing.expectEqual(@as(i64, 0), hourTokens(bare.value.object));
}
