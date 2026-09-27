//! ACP `compaction_update`: tell the client when the root agent compacts its
//! context, so it can show "Compacting…" and then "Context compacted" (or the
//! failure) instead of a context meter that silently drops.
//!
//! ACP v1 marks the update unstable: an agent may send it only when the client
//! advertised `clientCapabilities.session.compaction` at initialize. ACP v2
//! needs no capability. Anything else gets nothing from this module.
//!
//! A live ACP prompt turn installs a sink (acp_live_turn.zig); every
//! compaction site calls `start`, which is inert without one. A `Run` sends
//! `in_progress` once and exactly one final status, even on error paths.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

var client_opted_in = std.atomic.Value(bool).init(false);

/// From the `initialize` params: does this client take v1 compaction updates?
pub fn noteInitialize(params: ?Value) void {
    client_opted_in.store(advertises(params), .release);
}

fn advertises(params: ?Value) bool {
    const p = params orelse return false;
    if (p != .object) return false;
    const caps = p.object.get("clientCapabilities") orelse return false;
    if (caps != .object) return false;
    const session = caps.object.get("session") orelse return false;
    if (session != .object) return false;
    const compaction = session.object.get("compaction") orelse return false;
    return compaction == .object or (compaction == .bool and compaction.bool);
}

pub fn enabled() bool {
    return client_opted_in.load(.acquire) or @import("acp_v2.zig").on();
}

pub const Sink = struct {
    out: *Io.Writer,
    output_lock: *Io.Mutex,
    io: Io,
    session_id: []const u8,
    /// The agent's buffered event writer: flushed first so this update lands
    /// after everything the turn already produced.
    events: ?*Io.Writer = null,
    next: u32 = 0,
    active: bool = false,
};

var g_sink: ?*Sink = null;

pub fn install(sink: *Sink) void {
    g_sink = sink;
}

pub fn uninstall() void {
    g_sink = null;
}

pub const Status = enum { completed, failed, cancelled };

pub const Run = struct {
    sink: ?*Sink = null,
    id_buf: [32]u8 = undefined,
    id_len: usize = 0,

    fn id(self: *const Run) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    /// Close this compaction. Later calls do nothing, so a success path and a
    /// deferred failure path can both call it.
    pub fn finish(self: *Run, status: Status, summary: ?[]const u8, err_text: ?[]const u8) void {
        const sink = self.sink orelse return;
        self.sink = null;
        sink.active = false;
        send(sink, self.id(), @tagName(status), summary, err_text);
    }
};

/// Begin a compaction for the root agent. Inert for subagents, title calls,
/// clients without the capability, outside a live ACP turn, and when one is
/// already open (the outer compaction owns the report).
pub fn start(is_root: bool) Run {
    if (!is_root or !enabled()) return .{};
    const sink = g_sink orelse return .{};
    if (sink.active) return .{};
    sink.active = true;
    sink.next +%= 1;
    var run: Run = .{ .sink = sink };
    const written = std.fmt.bufPrint(&run.id_buf, "compaction-{d}", .{sink.next}) catch "compaction";
    run.id_len = written.len;
    send(sink, run.id(), "in_progress", null, null);
    return run;
}

/// A compaction the provider already finished on its own (in-stream).
pub fn completedNow(is_root: bool) void {
    var run = start(is_root);
    run.finish(.completed, null, null);
}

fn send(sink: *Sink, id: []const u8, status: []const u8, summary: ?[]const u8, err_text: ?[]const u8) void {
    if (sink.events) |events| events.flush() catch {};
    sink.output_lock.lockUncancelable(sink.io);
    defer sink.output_lock.unlock(sink.io);
    write(sink.out, sink.session_id, id, status, summary, err_text) catch return;
    sink.out.flush() catch {};
}

pub fn write(w: *Io.Writer, sid: []const u8, id: []const u8, status: []const u8, summary: ?[]const u8, err_text: ?[]const u8) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    const Block = struct { type: []const u8 = "text", text: []const u8 };
    const blocks: ?[1]Block = if (summary) |text| .{.{ .text = text }} else null;
    try s.write(.{ .jsonrpc = "2.0", .method = "session/update", .params = .{
        .sessionId = sid,
        .update = .{
            .sessionUpdate = "compaction_update",
            .compactionId = id,
            .status = status,
            .summary = blocks,
            .@"error" = err_text,
        },
    } });
    try w.writeByte('\n');
}

test "v1 clients opt in with clientCapabilities.session.compaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const yes = try std.json.parseFromSliceLeaky(Value, a, "{\"clientCapabilities\":{\"session\":{\"compaction\":{}}}}", .{});
    const no = try std.json.parseFromSliceLeaky(Value, a, "{\"clientCapabilities\":{\"fs\":{}}}", .{});
    try std.testing.expect(advertises(yes));
    try std.testing.expect(!advertises(no));
    try std.testing.expect(!advertises(null));
}

test "a run sends in_progress once and one final status, only when opted in" {
    var buf: [2048]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    var lock: Io.Mutex = .init;
    var sink: Sink = .{ .out = &out, .output_lock = &lock, .io = std.testing.io, .session_id = "s1" };
    install(&sink);
    defer uninstall();
    defer client_opted_in.store(false, .release);

    client_opted_in.store(false, .release);
    var off = start(true);
    off.finish(.completed, null, null);
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);

    client_opted_in.store(true, .release);
    var run = start(true);
    var nested = start(true); // the outer compaction owns the report
    nested.finish(.failed, null, "inner");
    var child = start(false); // subagents never report
    child.finish(.failed, null, "child");
    run.finish(.completed, "Kept the plan; dropped old tool output.", null);
    run.finish(.failed, null, "late"); // already closed
    const text = out.buffered();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "compaction_update"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"compactionId\":\"compaction-1\",\"status\":\"in_progress\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"status\":\"completed\",\"summary\":[{\"type\":\"text\",\"text\":\"Kept the plan; dropped old tool output.\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "inner") == null and std.mem.indexOf(u8, text, "late") == null);

    out = .fixed(&buf);
    completedNow(true);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.buffered(), "compaction_update"));
}
