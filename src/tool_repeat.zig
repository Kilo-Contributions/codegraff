//! Identical tool-batch loop guard (#1706).
//!
//! A model can repeat one call with the same input, get the same result, and
//! keep going until a wall clock kills the run. Nothing else ends that turn:
//! `tool_call_repair.brokenCallLoop` only covers unusable arguments, and the
//! dedupe gate in `agent_tools.rejectToolCall` is opt-in. Each executed batch
//! folds into a fingerprint of its normalized calls and their results; the
//! `nudge_at`-th identical batch in a row tells the model so, and the
//! `stop_at`-th ends the turn. A batch still waiting on work is never counted.
//! Reset at `runTurn`.

const std = @import("std");
const tools = @import("tools.zig");

pub const nudge_at: u8 = 4;
pub const stop_at: u8 = 8;

pub const nudge_text = std.fmt.comptimePrint("[graff] This call ran with this input and returned this result {d} times in a row. Repeating it will not make progress: take a different step, or finish with what you have.", .{nudge_at});

pub const stop_text = std.fmt.comptimePrint("Stopped: the model repeated the same tool call with the same result {d} times in a row, so the turn ended instead of running it again. Send a new message to continue, or switch models.", .{stop_at});

/// Turn-scoped run of identical batches. No heap.
pub const Tracker = struct {
    last: u64 = 0,
    run: u8 = 0,

    pub fn reset(self: *Tracker) void {
        self.* = .{};
    }

    /// Folds one batch; a null fingerprint (work still pending) breaks the run.
    pub fn note(self: *Tracker, fp: ?u64) u8 {
        const f = fp orelse {
            self.* = .{};
            return 0;
        };
        if (self.run > 0 and f == self.last) {
            self.run +|= 1;
        } else {
            self.last = f;
            self.run = 1;
        }
        return self.run;
    }

    pub fn stopped(self: *const Tracker) bool {
        return self.run >= stop_at;
    }
};

/// Null when any result is pending or cancelled: waiting is not repeating.
pub fn fingerprint(keys: []const []const u8, results: []const tools.ExecResult) ?u64 {
    var h = std.hash.Wyhash.init(0x1706);
    for (keys, results) |key, r| {
        if (r.pending or r.cancelled) return null;
        h.update(key);
        h.update(&.{ 0, @intFromBool(r.is_error) });
        h.update(r.text);
        h.update(&.{0});
    }
    return h.final();
}

/// After a batch ran: count it, and on the nudge append the notice to the
/// last result so the model reads it with what it just got back.
pub fn observe(self: anytype, calls: []const tools.ToolCall, results: []tools.ExecResult) !void {
    if (calls.len == 0) return;
    const keys = try self.arena.alloc([]const u8, calls.len);
    for (calls, keys) |call, *key| key.* = try self.toolDedupeKey(call);
    if (self.tool_repeat.note(fingerprint(keys, results)) != nudge_at) return;
    const last = &results[results.len - 1];
    last.text = try std.fmt.allocPrint(self.arena, "{s}\n\n{s}", .{ last.text, nudge_text });
}

test "identical batches build a run that stops at stop_at" {
    var t: Tracker = .{};
    const keys = [_][]const u8{"shell\n{\"command\":\"echo ok\"}"};
    const ok = [_]tools.ExecResult{.{ .text = "ok\n", .is_error = false }};
    var i: u8 = 1;
    while (i < stop_at) : (i += 1) {
        try std.testing.expectEqual(i, t.note(fingerprint(&keys, &ok)));
        try std.testing.expect(!t.stopped());
    }
    try std.testing.expectEqual(stop_at, t.note(fingerprint(&keys, &ok)));
    try std.testing.expect(t.stopped());
    t.reset();
    try std.testing.expect(!t.stopped());
}

test "a different input, result, or error flag starts a new run" {
    var t: Tracker = .{};
    const a = [_][]const u8{"shell\n{\"command\":\"echo ok\"}"};
    const b = [_][]const u8{"shell\n{\"command\":\"echo ko\"}"};
    const ok = [_]tools.ExecResult{.{ .text = "ok\n", .is_error = false }};
    const ok_err = [_]tools.ExecResult{.{ .text = "ok\n", .is_error = true }};
    const other = [_]tools.ExecResult{.{ .text = "ok 2\n", .is_error = false }};
    _ = t.note(fingerprint(&a, &ok));
    try std.testing.expectEqual(@as(u8, 2), t.note(fingerprint(&a, &ok)));
    try std.testing.expectEqual(@as(u8, 1), t.note(fingerprint(&b, &ok)));
    try std.testing.expectEqual(@as(u8, 1), t.note(fingerprint(&b, &other)));
    try std.testing.expectEqual(@as(u8, 1), t.note(fingerprint(&b, &ok_err)));
}

test "a pending or cancelled result never counts and breaks the run" {
    var t: Tracker = .{};
    const keys = [_][]const u8{"agent_output\n{\"id\":\"a1\"}"};
    const done = [_]tools.ExecResult{.{ .text = "still running", .is_error = false }};
    const waiting = [_]tools.ExecResult{.{ .text = "still running", .is_error = false, .pending = true }};
    const cancelled = [_]tools.ExecResult{.{ .text = "still running", .is_error = false, .cancelled = true }};
    _ = t.note(fingerprint(&keys, &done));
    _ = t.note(fingerprint(&keys, &done));
    try std.testing.expectEqual(@as(u8, 0), t.note(fingerprint(&keys, &waiting)));
    try std.testing.expectEqual(@as(u8, 1), t.note(fingerprint(&keys, &done)));
    try std.testing.expectEqual(@as(u8, 0), t.note(fingerprint(&keys, &cancelled)));
}

test "observe appends the notice on the nudge batch only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const Fake = struct {
        arena: std.mem.Allocator,
        tool_repeat: Tracker = .{},
        fn toolDedupeKey(_: *@This(), call: tools.ToolCall) ![]const u8 {
            return call.name;
        }
    };
    var fake: Fake = .{ .arena = arena_state.allocator() };
    const calls = [_]tools.ToolCall{.{ .id = "c", .name = "shell", .input = .null }};
    var i: u8 = 1;
    while (i <= nudge_at + 1) : (i += 1) {
        var results = [_]tools.ExecResult{.{ .text = "ok\n", .is_error = false }};
        try observe(&fake, &calls, &results);
        const noticed = std.mem.indexOf(u8, results[0].text, nudge_text) != null;
        try std.testing.expectEqual(i == nudge_at, noticed);
    }
}
