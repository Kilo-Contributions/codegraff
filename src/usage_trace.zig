//! One `usage` trace event per model response: the server's own token counts.
//!
//! The `api` event carries `context_tokens`, the context meter, which is the
//! larger of the server total and graff's local estimate of a full resend
//! (agent_context.zig). On a chained Codex request the server drops earlier
//! turns' reasoning while the local estimate still counts every retained
//! encrypted reasoning item, so `cache_read_tokens / context_tokens` is not a
//! cache hit rate. This event records what the server billed, split the same
//! way recordCost receives it, so trajectory analysis can compute
//! `cache_read_tokens / input_tokens` per request.
//!
//! recordCost only stashes the numbers (tests build partial agents whose
//! tracer is undefined); Tracer.api writes them right after its `api` line.
//! A request and its trace line run on the same thread, so the slot is
//! thread-local.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const cache_ttl = @import("cache_ttl.zig");
const hud = @import("prompt_cache_hud.zig");

const Usage = struct {
    provider: []const u8,
    input: i64,
    cache_read: i64,
    cache_write: i64,
    output: i64,
    chained: bool,
    /// #1320: why a read may have dropped. Time since this agent's previous
    /// request began, the TTL asked for (null: the provider default), whether
    /// the system+tools prefix changed and the named reason, and on a
    /// zero-read request with real input the likely cause.
    gap_ms: ?i64 = null,
    cache_ttl: ?[]const u8 = null,
    prefix_changed: bool = false,
    prefix_bust: ?[]const u8 = null,
    cache_miss: ?[]const u8 = null,
};

threadlocal var pending: ?Usage = null;

/// From recordCost: remember this response's usage for the next `api` line.
pub fn note(self: *const Agent, ordinary: i64, cache_read: i64, cache_write: i64, out: i64) void {
    const gap = cache_ttl.gap();
    // The prefix tracker follows the root session only.
    const snap = if (self.sub) hud.Snap{} else hud.snapshot();
    const input = ordinary + cache_read + cache_write;
    pending = .{
        .provider = self.provider.id,
        .input = input,
        .cache_read = cache_read,
        .cache_write = cache_write,
        .output = out,
        // Sent as previous_response_id + the new items on a held socket.
        .chained = self.codex_prev_id != null,
        .gap_ms = gap,
        .cache_ttl = if (cache_ttl.longTtl(self.provider.id, self.provider.model, gap)) "1h" else null,
        .prefix_changed = !snap.same,
        .prefix_bust = if (snap.same) null else hud.bustLabel(snap.last_bust),
        .cache_miss = cache_ttl.missReason(cache_read, input, !snap.same, gap),
    };
}

/// From Tracer.api on a successful call: write the pending usage, if any.
pub fn emit(tr: anytype, label: []const u8, from_sub: bool, model: []const u8) void {
    const u = pending orelse return;
    pending = null;
    tr.write(.{
        .t = tr.elapsedMs(),
        .ev = "usage",
        .agent = label,
        .from_sub = from_sub,
        .provider = u.provider,
        .model = model,
        .input_tokens = u.input,
        .cache_read_tokens = u.cache_read,
        .cache_write_tokens = u.cache_write,
        .output_tokens = u.output,
        .chained = u.chained,
        .gap_ms = u.gap_ms,
        .cache_ttl = u.cache_ttl,
        .prefix_changed = u.prefix_changed,
        .prefix_bust = u.prefix_bust,
        .cache_miss = u.cache_miss,
    });
}

/// From Tracer.api on a failed call: nothing was billed for it.
pub fn drop() void {
    pending = null;
}

test "usage waits for its api line and is written once" {
    const Sink = struct {
        lines: u32 = 0,
        last_input: i64 = 0,
        last_miss: ?[]const u8 = null,
        fn write(self: *@This(), event: anytype) void {
            self.lines += 1;
            self.last_input = event.input_tokens;
            self.last_miss = event.cache_miss;
        }
        fn elapsedMs(_: *@This()) i64 {
            return 0;
        }
    };
    var agent: Agent = undefined; // only provider, sub and codex_prev_id are read
    agent.provider.id = "codex";
    agent.codex_prev_id = null;
    agent.sub = true;
    agent.request_started = null;
    cache_ttl.begin(&agent); // this thread's slot: no previous request
    var sink: Sink = .{};
    note(&agent, 100, 900, 0, 7);
    emit(&sink, "main", false, "gpt-6-sol");
    emit(&sink, "main", false, "gpt-6-sol"); // taken: no second line
    try std.testing.expectEqual(@as(u32, 1), sink.lines);
    try std.testing.expectEqual(@as(i64, 1000), sink.last_input);
    try std.testing.expect(sink.last_miss == null);
    note(&agent, 1, 2, 3, 4);
    drop(); // the call failed
    emit(&sink, "main", false, "gpt-6-sol");
    try std.testing.expectEqual(@as(u32, 1), sink.lines);
    // #1320: a zero-read request says why.
    note(&agent, 50_000, 0, 0, 9);
    emit(&sink, "main", false, "gpt-6-sol");
    try std.testing.expectEqualStrings("first_request", sink.last_miss.?);
}

test {
    _ = cache_ttl;
}
