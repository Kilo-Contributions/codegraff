//! MCP stdio child-process shutdown and newline-delimited request/response.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// One newline-delimited JSON-RPC line. A payload that fills graff's 1 MiB
/// stdio reader used to surface as the opaque `WriteFailed` that auto-filed
/// #527/#528/#552; map the cap to a diagnosable error instead.
///
/// #1504: `takeDelimiter` leaves the stream unchanged on `StreamTooLong`, so
/// the oversized line stayed in the full buffer and every later call on the
/// server failed the same way. The rest of the line is now discarded. An
/// oversized notification is skipped (the reply being awaited follows it);
/// anything else fails only the call that was reading it.
pub fn takeLine(r: *Io.Reader) ![]u8 {
    while (true) {
        const line = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                const notification = isNotification(r.buffered());
                _ = r.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => return error.McpClosed,
                    else => return e,
                };
                if (notification) continue;
                return error.McpResponseTooLarge;
            },
            else => return err,
        };
        return line orelse error.McpClosed;
    }
}

/// Whether the start of a JSON-RPC line is a server notification: a
/// `"method"` naming `notifications/…` with no `"result"` or `"error"` ahead of
/// it. Only the line's prefix is available once it overflows the buffer.
fn isNotification(prefix: []const u8) bool {
    const head = prefix[0..@min(prefix.len, 4096)];
    const key = std.mem.indexOf(u8, head, "\"method\"") orelse return false;
    if (std.mem.indexOf(u8, head[0..key], "\"result\"") != null) return false;
    if (std.mem.indexOf(u8, head[0..key], "\"error\"") != null) return false;
    var rest = std.mem.trimStart(u8, head[key + "\"method\"".len ..], " \t");
    if (rest.len == 0 or rest[0] != ':') return false;
    rest = std.mem.trimStart(u8, rest[1..], " \t");
    return std.mem.startsWith(u8, rest, "\"notifications/");
}

/// Write one newline-delimited request. A dead child (binary replaced
/// mid-session) used to fail the write as `WriteFailed`.
pub fn writeRequest(w: *Io.Writer, body: []const u8) !void {
    w.writeAll(body) catch |err| return mapClosed(err);
    w.writeByte('\n') catch |err| return mapClosed(err);
    w.flush() catch |err| return mapClosed(err);
}

fn mapClosed(err: anyerror) anyerror {
    return switch (err) {
        error.WriteFailed => error.McpClosed,
        else => err,
    };
}

const shutdown_grace = std.Io.Duration.fromMilliseconds(100);

fn waitChild(child: *std.process.Child, io: Io) std.process.Child.WaitError!std.process.Child.Term {
    return child.wait(io);
}

fn shutdownDeadline(io: Io) void {
    io.sleep(shutdown_grace, .awake) catch {};
}

/// Signal a normal stdio-server shutdown with EOF, but never let a server's
/// SIGTERM handler stall the CLI. A child that does not exit within the grace
/// window is force-killed and reaped so one-shot/SDK callers do not inherit
/// teardown latency or zombies.
pub fn stopChild(io: Io, child: *std.process.Child) void {
    if (child.id == null) return;
    if (child.stdin) |stdin| {
        stdin.close(io);
        child.stdin = null;
    }

    const Done = union(enum) { exited: std.process.Child.WaitError!std.process.Child.Term, deadline: void };
    var done_buf: [2]Done = undefined;
    var sel: Io.Select(Done) = .init(io, &done_buf);
    sel.concurrent(.exited, waitChild, .{ child, io }) catch {
        child.kill(io);
        return;
    };
    sel.concurrent(.deadline, shutdownDeadline, .{io}) catch {
        _ = sel.await() catch {};
        sel.cancelDiscard();
        return;
    };
    const first = sel.await() catch {
        sel.cancelDiscard();
        child.kill(io);
        return;
    };
    sel.cancelDiscard();
    if (first == .exited or child.id == null) return;

    switch (builtin.os.tag) {
        .windows => child.kill(io),
        .wasi => unreachable,
        else => {
            std.posix.kill(child.id.?, .KILL) catch {};
            _ = child.wait(io) catch child.kill(io);
        },
    }
}

test "takeLine: one JSON-RPC line" {
    var reader: Io.Reader = .fixed("{\"ok\":true}\nnext\n");
    const line = try takeLine(&reader);
    try std.testing.expectEqualStrings("{\"ok\":true}", line);
}

/// A stream whose first line overflows a 64-byte reader buffer.
fn oversizedStream(comptime head: []const u8) []const u8 {
    const pad: [200]u8 = @splat('x');
    return head ++ pad ++ "\"}\n{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n";
}

test "takeLine #1504: an oversized notification is skipped and the reply still arrives" {
    var buf: [64]u8 = undefined;
    var tr: std.testing.Reader = .init(&buf, &.{.{ .buffer = oversizedStream("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"m\":\"") }});
    tr.artificial_limit = .limited(16);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}", try takeLine(&tr.interface));
}

test "takeLine #1504: an oversized reply fails its own call and the stream stays usable" {
    var buf: [64]u8 = undefined;
    var tr: std.testing.Reader = .init(&buf, &.{.{ .buffer = oversizedStream("{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{\"text\":\"") }});
    tr.artificial_limit = .limited(16);
    try std.testing.expectError(error.McpResponseTooLarge, takeLine(&tr.interface));
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}", try takeLine(&tr.interface));
}

test "isNotification reads only the JSON-RPC envelope" {
    try std.testing.expect(isNotification("{\"jsonrpc\":\"2.0\", \"method\" : \"notifications/message\",\"params\":{"));
    try std.testing.expect(!isNotification("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"sampling/createMessage\""));
    try std.testing.expect(!isNotification("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"method\":\"notifications/x\""));
    try std.testing.expect(!isNotification("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"text\":\"\\\"method\\\":\\\"notifications/x"));
}
