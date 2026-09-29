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

const Usage = struct {
    provider: []const u8,
    input: i64,
    cache_read: i64,
    cache_write: i64,
    output: i64,
    chained: bool,
};

threadlocal var pending: ?Usage = null;

/// From recordCost: remember this response's usage for the next `api` line.
pub fn note(self: *const Agent, ordinary: i64, cache_read: i64, cache_write: i64, out: i64) void {
    pending = .{
        .provider = self.provider.id,
        .input = ordinary + cache_read + cache_write,
        .cache_read = cache_read,
        .cache_write = cache_write,
        .output = out,
        // Sent as previous_response_id + the new items on a held socket.
        .chained = self.codex_prev_id != null,
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
        fn write(self: *@This(), event: anytype) void {
            self.lines += 1;
            self.last_input = event.input_tokens;
        }
        fn elapsedMs(_: *@This()) i64 {
            return 0;
        }
    };
    var agent: Agent = undefined; // only provider and codex_prev_id are read
    agent.provider.id = "codex";
    agent.codex_prev_id = null;
    var sink: Sink = .{};
    note(&agent, 100, 900, 0, 7);
    emit(&sink, "main", false, "gpt-6-sol");
    emit(&sink, "main", false, "gpt-6-sol"); // taken: no second line
    try std.testing.expectEqual(@as(u32, 1), sink.lines);
    try std.testing.expectEqual(@as(i64, 1000), sink.last_input);
    note(&agent, 1, 2, 3, 4);
    drop(); // the call failed
    emit(&sink, "main", false, "gpt-6-sol");
    try std.testing.expectEqual(@as(u32, 1), sink.lines);
}
