//! The loopback half of a browser sign-in: wait on the callback port for the
//! redirect that belongs to this attempt. A browser reaches the port for other
//! reasons too: a connection opened ahead of time and dropped unused, a
//! /favicon.ico, a tab left from an earlier attempt. None of those may end the
//! wait. The codex login used to answer only the first connection, so a spare
//! connection the browser closed unused ended it, and the real redirect then
//! found the port closed ("connection refused").

const std = @import("std");
const Io = std.Io;
const queryParam = @import("oauth_helpers.zig").queryParam;

pub const not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const stale_page = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nThis sign-in page is from an earlier attempt. Finish the newest one, or start the login again.\n";
const cancelled_page = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nSign-in cancelled.\n";

pub const Kind = enum { other, stale, cancel, mine };

/// One request line on the callback port: this attempt's redirect (its
/// `state`), a redirect from an earlier attempt, a /cancel from a newer
/// sign-in that needs the port, or anything else.
pub fn classify(req_line: []const u8, path: []const u8, state: []const u8) Kind {
    var parts = std.mem.tokenizeScalar(u8, req_line, ' ');
    _ = parts.next() orelse return .other;
    const target = parts.next() orelse return .other;
    const route = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (std.mem.eql(u8, route, "/cancel")) return .cancel;
    if (!std.mem.eql(u8, route, path)) return .other;
    const got = queryParam(req_line, "state") orelse return .stale;
    return if (std.mem.eql(u8, got, state)) .mine else .stale;
}

/// This attempt's redirect. `line` points into the caller's buffer; answer on
/// `stream`, then close it.
pub const Callback = struct { stream: Io.net.Stream, line: []const u8 };

/// Accept until this attempt's redirect arrives, answering and skipping
/// everything else. error.Cancelled: a newer sign-in asked for the port.
pub fn wait(io: Io, server: *Io.net.Server, path: []const u8, state: []const u8, buf: []u8) !Callback {
    while (true) {
        const stream = try server.accept(io);
        var reader = Io.net.Stream.Reader.init(stream, io, buf);
        const line = (reader.interface.takeDelimiter('\n') catch null) orelse {
            stream.close(io); // closed before sending a request
            continue;
        };
        const kind = classify(line, path, state);
        if (kind == .mine) return .{ .stream = stream, .line = line };
        answer(io, stream, switch (kind) {
            .stale => stale_page,
            .cancel => cancelled_page,
            else => not_found,
        });
        stream.close(io);
        if (kind == .cancel) return error.Cancelled;
    }
}

pub fn answer(io: Io, stream: Io.net.Stream, response: []const u8) void {
    var wbuf: [1024]u8 = undefined;
    var w = Io.net.Stream.Writer.init(stream, io, &wbuf);
    w.interface.writeAll(response) catch {};
    w.interface.flush() catch {};
}

/// Bind 127.0.0.1:`port` for the redirect. When an earlier sign-in still
/// holds it (graff's or the Codex CLI's; both answer /cancel), ask it to let
/// go and retry for about two seconds, as the Codex CLI's own login does.
pub fn listen(io: Io, port: u16) !Io.net.Server {
    var buf: [32]u8 = undefined;
    var addr = try Io.net.IpAddress.parseLiteral(try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port}));
    var tries: usize = 0;
    while (true) : (tries += 1) {
        return Io.net.IpAddress.listen(&addr, io, .{}) catch |err| {
            if (err != error.AddressInUse or tries == 10) return err;
            if (tries == 0) cancelHolder(io, &addr);
            io.sleep(.fromMilliseconds(200), .awake) catch {};
            continue;
        };
    }
}

fn cancelHolder(io: Io, addr: *const Io.net.IpAddress) void {
    const stream = addr.connect(io, .{ .mode = .stream }) catch return;
    defer stream.close(io);
    answer(io, stream, "GET /cancel HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
}

test "classify: only this attempt's redirect is the callback" {
    const s = "Nh-So_9HxnY6gdCtrPC_ig";
    try std.testing.expectEqual(Kind.mine, classify("GET /auth/callback?code=ac_1&scope=openid&state=" ++ s ++ " HTTP/1.1\r", "/auth/callback", s));
    try std.testing.expectEqual(Kind.mine, classify("GET /auth/callback?error=access_denied&state=" ++ s ++ " HTTP/1.1\r", "/auth/callback", s));
    try std.testing.expectEqual(Kind.stale, classify("GET /auth/callback?code=ac_0&state=older HTTP/1.1\r", "/auth/callback", s));
    try std.testing.expectEqual(Kind.stale, classify("GET /auth/callback?code=ac_0 HTTP/1.1\r", "/auth/callback", s));
    try std.testing.expectEqual(Kind.other, classify("GET /favicon.ico HTTP/1.1\r", "/auth/callback", s));
    try std.testing.expectEqual(Kind.other, classify("GET /auth/callbackx?state=" ++ s ++ " HTTP/1.1\r", "/auth/callback", s));
    try std.testing.expectEqual(Kind.other, classify("", "/auth/callback", s));
    try std.testing.expectEqual(Kind.cancel, classify("GET /cancel HTTP/1.1\r", "/auth/callback", s));
}

const Visitor = struct {
    fn send(io: Io, port: u16, request: []const u8) []const u8 {
        var buf: [32]u8 = undefined;
        const addr = Io.net.IpAddress.parseLiteral(std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port}) catch return "") catch return "";
        const stream = addr.connect(io, .{ .mode = .stream }) catch return "";
        defer stream.close(io);
        if (request.len == 0) return ""; // connect and hang up, like a spare browser connection
        answer(io, stream, request);
        var rbuf: [256]u8 = undefined;
        var r = Io.net.Stream.Reader.init(stream, io, &rbuf);
        const status = (r.interface.takeDelimiter('\n') catch null) orelse return "";
        if (std.mem.startsWith(u8, status, "HTTP/1.1 404")) return "404";
        if (std.mem.startsWith(u8, status, "HTTP/1.1 400")) return "400";
        return "other";
    }

    fn run(io: Io, port: u16, statuses: *[3][]const u8) void {
        _ = send(io, port, "");
        statuses[0] = send(io, port, "GET /favicon.ico HTTP/1.1\r\nHost: localhost\r\n\r\n");
        statuses[1] = send(io, port, "GET /auth/callback?code=ac_old&state=older HTTP/1.1\r\nHost: localhost\r\n\r\n");
        statuses[2] = send(io, port, "GET /auth/callback?code=ac_new&state=s1 HTTP/1.1\r\nHost: localhost\r\n\r\n");
    }
};

test "wait: a dropped connection, a favicon and an older tab do not end the sign-in" {
    const io = std.testing.io;
    var server = try listen(io, 0);
    defer server.deinit(io);
    var statuses: [3][]const u8 = .{ "", "", "" };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Visitor.run, .{ io, server.socket.address.getPort(), &statuses });
    var buf: [4096]u8 = undefined;
    const cb = try wait(io, &server, "/auth/callback", "s1", &buf);
    try std.testing.expectEqualStrings("ac_new", queryParam(cb.line, "code").?);
    answer(io, cb.stream, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    cb.stream.close(io);
    try group.await(io);
    try std.testing.expectEqualStrings("404", statuses[0]);
    try std.testing.expectEqualStrings("400", statuses[1]);
    try std.testing.expectEqualStrings("other", statuses[2]);
}

fn waitForCancel(io: Io, server: *Io.net.Server, got: *?anyerror) void {
    var buf: [1024]u8 = undefined;
    if (wait(io, server, "/auth/callback", "s1", &buf)) |cb| cb.stream.close(io) else |err| got.* = err;
    server.deinit(io);
}

test "listen: a newer sign-in takes the port from one still waiting" {
    const io = std.testing.io;
    var first = try listen(io, 0);
    const port = first.socket.address.getPort();
    var got: ?anyerror = null;
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, waitForCancel, .{ io, &first, &got });
    var second = try listen(io, port);
    defer second.deinit(io);
    try group.await(io);
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), got);
}
