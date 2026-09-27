//! Server-to-client MCP notifications that arrive while graff waits for a
//! reply: on a stdio pipe between response lines, or as extra events in a
//! Streamable HTTP SSE response. Before this they were read and dropped.
//!
//! - `notifications/tools/list_changed` marks the server's catalog stale;
//!   `mcp_pages.refreshStale` re-lists it before the next model request.
//! - `notifications/progress` for a call graff tagged with a progress token
//!   becomes a transient progress line, like a long shell job's pulse.
//! - An SSE `id:` field is remembered so a stream that drops before the
//!   reply can be resumed with `Last-Event-ID` (mcp_http.resume).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Sink = struct {
    server: []const u8 = "",
    tools_stale: std.atomic.Value(bool) = .init(false),
    last_event_id: [128]u8 = undefined,
    last_event_len: u8 = 0,

    pub fn noteEventId(self: *Sink, id: []const u8) void {
        const n: u8 = @intCast(@min(id.len, self.last_event_id.len));
        @memcpy(self.last_event_id[0..n], id[0..n]);
        self.last_event_len = n;
    }

    pub fn lastEventId(self: *const Sink) ?[]const u8 {
        return if (self.last_event_len == 0) null else self.last_event_id[0..self.last_event_len];
    }

    pub fn clearEventId(self: *Sink) void {
        self.last_event_len = 0;
    }
};

/// Where progress lines go: a transient notice like a shell job's pulse.
/// Null drops them.
pub var on_progress: ?*const fn (io: Io, server: []const u8, text: []const u8) void = pulse;

fn pulse(io: Io, server: []const u8, text: []const u8) void {
    @import("tool_pulse.zig").emitNotice(io, "· mcp:{s} · {s}", .{ server, text });
}

pub const Kind = enum { none, tools_changed, progress };

/// Inspect one JSON-RPC message that is not the awaited reply. Returns what
/// it was so callers and tests can tell.
pub fn observe(sink: *Sink, io: Io, bytes: []const u8) Kind {
    var buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 8 * 1024) return .none;
    const v = std.json.parseFromSliceLeaky(Value, fba.allocator(), trimmed, .{}) catch return .none;
    if (v != .object) return .none;
    const method = v.object.get("method") orelse return .none;
    if (method != .string or v.object.get("id") != null) return .none; // requests are answered elsewhere
    if (std.mem.eql(u8, method.string, "notifications/tools/list_changed")) {
        sink.tools_stale.store(true, .release);
        return .tools_changed;
    }
    if (std.mem.eql(u8, method.string, "notifications/progress")) {
        const params = v.object.get("params") orelse return .progress;
        if (params != .object) return .progress;
        var line: [256]u8 = undefined;
        const text = progressText(&line, params.object);
        if (on_progress) |emit| if (text.len > 0) emit(io, sink.server, text);
        return .progress;
    }
    return .none;
}

fn number(v: ?Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// `3/10 indexing files`, `3 indexing files`, or `3/10`.
pub fn progressText(buf: []u8, params: std.json.ObjectMap) []const u8 {
    const done = number(params.get("progress")) orelse return "";
    const message = if (params.get("message")) |m| (if (m == .string) m.string else "") else "";
    const msg = message[0..@min(message.len, 160)];
    if (number(params.get("total"))) |total|
        return std.fmt.bufPrint(buf, "{d}/{d}{s}{s}", .{ done, total, if (msg.len > 0) " " else "", msg }) catch "";
    return std.fmt.bufPrint(buf, "{d}{s}{s}", .{ done, if (msg.len > 0) " " else "", msg }) catch "";
}

/// Tag a built JSON-RPC request line with `_meta.progressToken` = its id so
/// the server may report progress. Only for `tools/call`; every other request
/// keeps its exact bytes.
pub fn withProgressToken(a: Allocator, line: []const u8, id: i64) ![]const u8 {
    const key = "\"params\":{";
    const at = std.mem.indexOf(u8, line, key) orelse return line;
    const after = at + key.len;
    const rest = line[after..];
    if (std.mem.startsWith(u8, rest, "\"_meta\":{"))
        return std.fmt.allocPrint(a, "{s}\"_meta\":{{\"progressToken\":{d},{s}", .{ line[0..after], id, rest["\"_meta\":{".len..] });
    const sep: []const u8 = if (std.mem.startsWith(u8, rest, "}")) "" else ",";
    return std.fmt.allocPrint(a, "{s}\"_meta\":{{\"progressToken\":{d}}}{s}{s}", .{ line[0..after], id, sep, rest });
}

/// `notifications/cancelled` for request `id` (one line, no trailing newline).
pub fn cancelledLine(a: Allocator, id: i64) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"jsonrpc":"2.0","method":"notifications/cancelled","params":{{"requestId":{d},"reason":"cancelled by the user"}}}}
    , .{id});
}

const testing = std.testing;

test "observe marks the catalog stale and reports progress" {
    var sink: Sink = .{ .server = "demo" };
    try testing.expectEqual(Kind.tools_changed, observe(&sink, testing.io,
        \\{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}
    ));
    try testing.expect(sink.tools_stale.load(.acquire));
    try testing.expectEqual(Kind.progress, observe(&sink, testing.io,
        \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":4,"progress":3,"total":10,"message":"indexing"}}
    ));
    try testing.expectEqual(Kind.none, observe(&sink, testing.io,
        \\{"jsonrpc":"2.0","id":9,"method":"roots/list"}
    ));
    try testing.expectEqual(Kind.none, observe(&sink, testing.io, "not json"));
}

test "progressText formats with and without a total" {
    var buf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p1 = try std.json.parseFromSliceLeaky(Value, a, "{\"progress\":3,\"total\":10,\"message\":\"indexing\"}", .{});
    try testing.expectEqualStrings("3/10 indexing", progressText(&buf, p1.object));
    const p2 = try std.json.parseFromSliceLeaky(Value, a, "{\"progress\":7}", .{});
    try testing.expectEqualStrings("7", progressText(&buf, p2.object));
}

test "withProgressToken merges into an existing _meta or adds one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = try withProgressToken(a, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"t\",\"arguments\":{}}}", 5);
    const lv = try std.json.parseFromSliceLeaky(Value, a, legacy, .{});
    try testing.expectEqual(@as(i64, 5), lv.object.get("params").?.object.get("_meta").?.object.get("progressToken").?.integer);
    try testing.expectEqualStrings("t", lv.object.get("params").?.object.get("name").?.string);
    const modern = try withProgressToken(a, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"},\"name\":\"t\"}}", 6);
    const mv = try std.json.parseFromSliceLeaky(Value, a, modern, .{});
    const meta = mv.object.get("params").?.object.get("_meta").?.object;
    try testing.expectEqual(@as(i64, 6), meta.get("progressToken").?.integer);
    try testing.expect(meta.get("io.modelcontextprotocol/protocolVersion") != null);
    const empty = try withProgressToken(a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{}}", 7);
    _ = try std.json.parseFromSliceLeaky(Value, a, empty, .{});
}

test "sink remembers the last SSE event id" {
    var sink: Sink = .{};
    try testing.expect(sink.lastEventId() == null);
    sink.noteEventId("evt-42");
    try testing.expectEqualStrings("evt-42", sink.lastEventId().?);
    sink.clearEventId();
    try testing.expect(sink.lastEventId() == null);
}
