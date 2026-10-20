//! #1686: calibrate compaction state from the provider's own count. A full
//! (unchained) Responses request carrying a compaction item reports its input
//! tokens; the state's share replaces the bytes/16 estimate for that state
//! (context_tokens.learnState). A chained request sends only a delta, so its
//! count says nothing about the state and is skipped.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const context_tokens = @import("context_tokens.zig");

pub fn learn(self: *Agent, response: std.json.ObjectMap) void {
    if (self.codex_prev_id != null) return;
    const usage = response.get("usage") orelse return;
    if (usage != .object) return;
    const input = usage.object.get("input_tokens") orelse return;
    if (input != .integer or input.integer <= 0) return;
    const history: std.json.Value = .{ .array = self.messages };
    const bytes = context_tokens.compactionStateBytes(history);
    if (bytes == 0) return;
    context_tokens.learnState(bytes, @intCast(input.integer), self.fullRequestEstimateTokens());
}
