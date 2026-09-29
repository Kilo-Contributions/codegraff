//! #1285: a client that loses its connection mid-send cannot tell whether its
//! request landed, so it resends it, and without an id the resend started a
//! second turn. A request may carry a client message id: `message_id` on a
//! serve or remote-control body, `messageId` or `_meta["graff/messageId"]` on
//! ACP session/prompt. The first request with an id runs; a repeat of a
//! finished one is answered from its record instead: serve and remote control
//! replay its events from the session tape, ACP returns its stop reason. A
//! repeat that arrives while the first still runs waits behind it (the
//! per-session request lock) and is then answered the same way.
//!
//! In memory and bounded: an id older than the last `cap` on the session, or
//! one from before a restart, runs again.

const std = @import("std");

/// Longest id accepted; anything longer is treated as no id.
pub const max_id_len = 128;

pub const Entry = struct {
    key: u64,
    done: bool = false,
    /// Serve / remote-control tape: this request's first event and its terminal one.
    first_seq: u64 = 0,
    last_seq: u64 = 0,
    /// ACP: the stop reason the first turn ended with.
    stop_buf: [32]u8 = undefined,
    stop_len: u8 = 0,

    pub fn stopReason(self: *const Entry) []const u8 {
        return self.stop_buf[0..self.stop_len];
    }
};

pub const Ledger = struct {
    pub const cap = 32;
    entries: [cap]Entry = undefined,
    len: usize = 0,
    next: usize = 0, // oldest slot once full

    /// `scope` separates sessions sharing one ledger (ACP); serve passes "".
    pub fn keyOf(scope: []const u8, id: []const u8) u64 {
        var h = std.hash.Wyhash.init(0x1285);
        h.update(scope);
        h.update("\x00");
        h.update(id);
        return h.final();
    }

    /// The finished request this id already ran, if still remembered.
    pub fn finished(self: *Ledger, key: u64) ?Entry {
        for (self.entries[0..self.len]) |e| if (e.key == key and e.done) return e;
        return null;
    }

    /// A request with this id starts. An unfinished earlier one (its handler
    /// failed before the terminal event) is replaced: that turn never ended.
    pub fn begin(self: *Ledger, key: u64, first_seq: u64) void {
        for (self.entries[0..self.len]) |*e| if (e.key == key) {
            e.* = .{ .key = key, .first_seq = first_seq };
            return;
        };
        const slot = if (self.len < cap) blk: {
            self.len += 1;
            break :blk self.len - 1;
        } else blk: {
            const oldest = self.next;
            self.next = (self.next + 1) % cap;
            break :blk oldest;
        };
        self.entries[slot] = .{ .key = key, .first_seq = first_seq };
    }

    pub fn finish(self: *Ledger, key: u64, last_seq: u64, stop: []const u8) void {
        for (self.entries[0..self.len]) |*e| if (e.key == key) {
            e.done = true;
            e.last_seq = last_seq;
            e.stop_len = @intCast(@min(stop.len, e.stop_buf.len));
            @memcpy(e.stop_buf[0..e.stop_len], stop[0..e.stop_len]);
            return;
        };
    }
};

fn usable(v: ?std.json.Value) ?[]const u8 {
    const s = v orelse return null;
    if (s != .string or s.string.len == 0 or s.string.len > max_id_len) return null;
    return s.string;
}

/// Serve / remote control: the body's `message_id`.
pub fn bodyId(body: std.json.ObjectMap) ?[]const u8 {
    return usable(body.get("message_id"));
}

/// ACP session/prompt params: `messageId`, else `_meta["graff/messageId"]`.
pub fn acpId(params: std.json.ObjectMap) ?[]const u8 {
    if (usable(params.get("messageId"))) |id| return id;
    const meta = params.get("_meta") orelse return null;
    if (meta != .object) return null;
    return usable(meta.object.get("graff/messageId"));
}

/// Tape lines with `from <= seq <= to`, in order: the first request's events.
pub fn replayRange(w: *std.Io.Writer, data: []const u8, from: u64, to: u64) !usize {
    const seqOf = @import("protocol_seq.zig").seqOf;
    var emitted: usize = 0;
    var rest = data;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const line = std.mem.trim(u8, rest[0..nl], " \t\r");
        rest = rest[nl + 1 ..];
        const seq = seqOf(line) orelse continue;
        if (seq < from or seq > to) continue;
        try w.writeAll(line);
        try w.writeByte('\n');
        emitted += 1;
    }
    return emitted;
}

test "#1285: a finished id is answered from its record; an unfinished one runs again" {
    var ledger: Ledger = .{};
    const a = Ledger.keyOf("s1", "m-1");
    try std.testing.expect(ledger.finished(a) == null);
    ledger.begin(a, 7);
    try std.testing.expect(ledger.finished(a) == null); // still running
    ledger.finish(a, 12, "end_turn");
    const prior = ledger.finished(a).?;
    try std.testing.expectEqual(@as(u64, 7), prior.first_seq);
    try std.testing.expectEqual(@as(u64, 12), prior.last_seq);
    try std.testing.expectEqualStrings("end_turn", prior.stopReason());
    // The same id in another session is a different request.
    try std.testing.expect(ledger.finished(Ledger.keyOf("s2", "m-1")) == null);
    // A restarted request replaces the record until it finishes.
    ledger.begin(a, 20);
    try std.testing.expect(ledger.finished(a) == null);
}

test "#1285: the ledger keeps the most recent ids" {
    var ledger: Ledger = .{};
    var i: u64 = 0;
    while (i < Ledger.cap + 5) : (i += 1) {
        var buf: [16]u8 = undefined;
        const key = Ledger.keyOf("", std.fmt.bufPrint(&buf, "m{d}", .{i}) catch unreachable);
        ledger.begin(key, i);
        ledger.finish(key, i, "");
    }
    try std.testing.expect(ledger.finished(Ledger.keyOf("", "m0")) == null); // evicted
    try std.testing.expect(ledger.finished(Ledger.keyOf("", "m36")) != null);
}

test "#1285: ids come from the body or the ACP params, bounded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"type\":\"user\",\"text\":\"hi\",\"message_id\":\"m-7\"}", .{});
    try std.testing.expectEqualStrings("m-7", bodyId(body.object).?);
    const meta = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"sessionId\":\"s\",\"_meta\":{\"graff/messageId\":\"m-8\"}}", .{});
    try std.testing.expectEqualStrings("m-8", acpId(meta.object).?);
    const top = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"messageId\":\"m-9\",\"_meta\":{\"graff/messageId\":\"x\"}}", .{});
    try std.testing.expectEqualStrings("m-9", acpId(top.object).?);
    const none = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"message_id\":\"\"}", .{});
    try std.testing.expect(bodyId(none.object) == null);
}

test "#1285: replayRange returns exactly the first request's events" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const tape = "{\"seq\":1,\"type\":\"a\"}\n{\"seq\":2,\"type\":\"b\"}\n{\"seq\":3,\"type\":\"turn\"}\n{\"seq\":4,\"type\":\"c\"}\n";
    try std.testing.expectEqual(@as(usize, 2), try replayRange(&out.writer, tape, 2, 3));
    try std.testing.expectEqualStrings("{\"seq\":2,\"type\":\"b\"}\n{\"seq\":3,\"type\":\"turn\"}\n", out.written());
}

test "#1285: ACP answers a resent prompt from the first turn" {
    const engine = @import("acp_engine.zig");
    const v2 = @import("acp_v2.zig");
    const Counter = struct {
        var turns: u32 = 0;
        fn turn(_: *anyopaque, arena: std.mem.Allocator, text: []const u8) anyerror![]const u8 {
            turns += 1;
            return std.fmt.allocPrint(arena, "ran:{s}", .{text});
        }
    };
    const gate = v2.gate;
    v2.gate = false;
    defer v2.gate = gate;
    engine.resent = .{};
    defer engine.resent = .{};
    Counter.turns = 0;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var d: engine.Dispatch = .{ .turn = Counter.turn, .ctx = undefined };
    try engine.handleLine(&d, a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}");
    try engine.handleLine(&d, a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\"}");
    const send = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s1\",\"prompt\":\"x\",\"_meta\":{\"graff/messageId\":\"m-1\"}}}";
    const resend = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s1\",\"prompt\":\"x\",\"_meta\":{\"graff/messageId\":\"m-1\"}}}";
    try engine.handleLine(&d, a, &out.writer, send);
    try engine.handleLine(&d, a, &out.writer, resend);
    try std.testing.expectEqual(@as(u32, 1), Counter.turns);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":4,\"result\":{\"stopReason\":\"end_turn\"}") != null);
    // A new id, or the same id in another session, is a new turn.
    try engine.handleLine(&d, a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s1\",\"prompt\":\"y\",\"messageId\":\"m-2\"}}");
    try engine.handleLine(&d, a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s2\",\"prompt\":\"x\",\"_meta\":{\"graff/messageId\":\"m-1\"}}}");
    try std.testing.expectEqual(@as(u32, 3), Counter.turns);
}
