//! One process per machine for a stateless MCP server (`"shared": true`).
//!
//! Most stdio servers hold per-agent state (a browser, a working directory,
//! credentials) and stay one process per session. A stateless one (time,
//! fetch, sequential-thinking, a docs search) can serve every session: its
//! entry is launched as `graff mcp attach --key K -- <command…>`, a relay that
//! connects to a per-machine broker over a Unix socket and starts it when it
//! is not running. The broker runs the real server once and multiplexes
//! JSON-RPC: request ids are rewritten per client and restored on the reply,
//! a repeated `initialize` is answered from the first one, server
//! notifications go to every client, and server-to-client requests are
//! refused (a shared server has no single client to ask). It exits once no
//! client has been connected for `GRAFF_MCP_SHARED_IDLE_S` (default 60).
//!
//! POSIX only; on Windows the entry runs as an ordinary per-session server.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const supported = builtin.os.tag != .windows;

/// Whether an entry asks to be shared (and can be, on this OS).
pub fn wantsShared(cfg: std.json.ObjectMap) bool {
    if (!supported or cfg.get("command") == null) return false;
    const v = cfg.get("shared") orelse return false;
    return v == .bool and v.bool;
}

/// The broker a config maps to: command, args, env overlay and cwd, so two
/// entries share a process only when they would launch the same one.
pub fn keyFor(cfg: std.json.ObjectMap) [16]u8 {
    var h = std.hash.Wyhash.init(0x6d6370);
    const parts = [_][]const u8{ "command", "args", "env", "cwd" };
    for (parts) |p| {
        h.update(p);
        if (cfg.get(p)) |v| hashValue(&h, v);
    }
    return std.fmt.bytesToHex(std.mem.asBytes(&h.final()), .lower);
}

fn hashValue(h: *std.hash.Wyhash, v: Value) void {
    switch (v) {
        .string => |s| {
            h.update("s");
            h.update(s);
        },
        .array => |arr| {
            h.update("[");
            for (arr.items) |x| hashValue(h, x);
            h.update("]");
        },
        .object => |o| {
            // Key order must not change the key: fold entries order-independently.
            var acc: u64 = 0;
            var it = o.iterator();
            while (it.next()) |e| {
                var eh = std.hash.Wyhash.init(1);
                eh.update(e.key_ptr.*);
                hashValue(&eh, e.value_ptr.*);
                acc +%= eh.final();
            }
            h.update("{");
            h.update(std.mem.asBytes(&acc));
        },
        .bool => |b| h.update(if (b) "t" else "f"),
        .integer => |i| h.update(std.mem.asBytes(&i)),
        else => h.update("?"),
    }
}

/// argv for a shared entry: the relay, keyed, followed by the real command.
pub fn attachArgv(a: Allocator, self_exe: []const u8, key: []const u8, argv: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, &.{ self_exe, "mcp", "attach", "--key", key, "--" });
    try out.appendSlice(a, argv);
    return out.items;
}

/// `/tmp/graff-<uid>/mcp-<hash>.sock`: short enough for the 104-byte socket
/// path limit whatever HOME is, and the home is folded into the name so two
/// homes never share a broker. The directory must be ours and private, or a
/// local user could plant a socket that answers our agents' tool calls.
pub fn socketPath(a: Allocator, home: []const u8, key: []const u8) ![]const u8 {
    const uid = std.c.getuid();
    const dir = try std.fmt.allocPrint(a, "/tmp/graff-{d}", .{uid});
    try privateDir(a, dir, uid);
    var h = std.hash.Wyhash.init(0x736f636b);
    h.update(home);
    h.update(key);
    return std.fmt.allocPrint(a, "{s}/mcp-{s}.sock", .{ dir, &std.fmt.bytesToHex(std.mem.asBytes(&h.final()), .lower) });
}

fn privateDir(a: Allocator, dir: []const u8, uid: std.c.uid_t) !void {
    const z = try a.dupeSentinel(u8, dir, 0);
    _ = std.c.mkdir(z, 0o700);
    const st = try lstatOwner(z);
    const is_dir = (st.mode & std.c.S.IFMT) == std.c.S.IFDIR;
    if (!is_dir or st.uid != uid or (st.mode & 0o077) != 0) return error.SharedMcpDirNotPrivate;
}

/// Mode and owner of `z` itself, not a symlink's target. Linux libc has no
/// `fstatat` binding here, so it goes through `statx`.
fn lstatOwner(z: [*:0]const u8) !struct { mode: u32, uid: std.c.uid_t } {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &sx);
        if (linux.errno(rc) != .SUCCESS) return error.SharedMcpDirUnavailable;
        return .{ .mode = sx.mode, .uid = sx.uid };
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, z, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return error.SharedMcpDirUnavailable;
    return .{ .mode = st.mode, .uid = st.uid };
}

// ── JSON-RPC id plumbing (pure; unit-tested) ──────────────────────────────

pub const Kind = enum { request, notification, response, server_request, other };

pub fn classify(msg: Value) Kind {
    if (msg != .object) return .other;
    const has_id = msg.object.get("id") != null;
    const has_method = msg.object.get("method") != null;
    if (has_method and has_id) return .request;
    if (has_method) return .notification;
    if (has_id and (msg.object.get("result") != null or msg.object.get("error") != null)) return .response;
    return .other;
}

/// The same message with its `id` replaced, serialized as one line.
pub fn withId(a: Allocator, msg: Value, id: Value) ![]const u8 {
    var copy = msg.object;
    copy = try copy.clone(a);
    try copy.put(a, "id", id);
    var aw: Io.Writer.Allocating = .init(a);
    var js: std.json.Stringify = .{ .writer = &aw.writer };
    try js.write(Value{ .object = copy });
    return aw.writer.buffered();
}

// ── relay: graff mcp attach --key K -- command… ───────────────────────────

pub fn attach(io: Io, gpa: Allocator, a: Allocator, home: []const u8, args: []const []const u8) !void {
    if (!supported) return error.SharedMcpUnsupported;
    if (args.len < 4 or !std.mem.eql(u8, args[0], "--key") or !std.mem.eql(u8, args[2], "--")) return error.Usage;
    const key = args[1];
    const command = args[3..];
    const path = try socketPath(a, home, key);
    const stream = connectOrStart(io, a, path, key, command) orelse return error.SharedMcpUnavailable;
    defer stream.close(io);
    const up = try std.Thread.spawn(.{}, pump, .{ io, Io.File.stdin(), stream });
    up.detach();
    // Down: broker → stdout until the broker closes the connection.
    var rbuf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var wbuf: [64 * 1024]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &wbuf);
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch break;
        w.interface.writeAll(line) catch break;
        w.interface.flush() catch break;
    }
    _ = gpa;
}

fn pump(io: Io, from: Io.File, to: net.Stream) void {
    var rbuf: [64 * 1024]u8 = undefined;
    var r = from.readerStreaming(io, &rbuf);
    var wbuf: [64 * 1024]u8 = undefined;
    var w = to.writer(io, &wbuf);
    while (true) {
        const line = r.interface.takeDelimiterInclusive('\n') catch break;
        w.interface.writeAll(line) catch break;
        w.interface.flush() catch break;
    }
    // The session closed its end: tell the broker this client is gone.
    to.shutdown(io, .send) catch {};
}

fn connect(io: Io, path: []const u8) ?net.Stream {
    const addr = net.UnixAddress.init(path) catch return null;
    return addr.connect(io) catch null;
}

fn connectOrStart(io: Io, a: Allocator, path: []const u8, key: []const u8, command: []const []const u8) ?net.Stream {
    if (connect(io, path)) |s| return s;
    const self_exe = std.process.executablePathAlloc(io, a) catch return null;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ self_exe, "mcp", "broker", "--key", key, "--" }) catch return null;
    argv.appendSlice(a, command) catch return null;
    // Its own process group: the broker outlives the session that started it.
    _ = std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .pgid = 0 }) catch return null;
    var waited: u32 = 0;
    while (waited < 200) : (waited += 1) { // up to ~10 s for the server to start
        if (connect(io, path)) |s| return s;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return null;
}

// ── broker: graff mcp broker --key K -- command… ──────────────────────────

const Client = struct {
    stream: net.Stream,
    writer: net.Stream.Writer,
    wbuf: [64 * 1024]u8 = undefined,
    alive: bool = true,
};

const Pending = struct { client: *Client, id: Value };

const Broker = struct {
    io: Io,
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    clients: std.ArrayList(*Client) = .empty,
    pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
    next_id: i64 = 1,
    init_result: ?[]const u8 = null, // the first initialize result, as JSON
    // An initialize is at the server: later ones wait for its answer here
    // instead of reaching the server a second time.
    init_inflight: bool = false,
    init_server_id: i64 = 0,
    init_waiters: std.ArrayList(Pending) = .empty,
    initialized_sent: bool = false,
    server_in: Io.File.Writer,
    last_client_left_ms: i64 = 0,
    ids_arena: std.heap.ArenaAllocator,

    fn toServer(b: *Broker, line: []const u8) void {
        b.server_in.interface.writeAll(line) catch return;
        b.server_in.interface.writeByte('\n') catch return;
        b.server_in.interface.flush() catch {};
    }

    fn toClient(b: *Broker, c: *Client, line: []const u8) void {
        _ = b;
        if (!c.alive) return;
        c.writer.interface.writeAll(line) catch {
            c.alive = false;
            return;
        };
        c.writer.interface.writeByte('\n') catch {};
        c.writer.interface.flush() catch {
            c.alive = false;
        };
    }

    /// `{"jsonrpc":"2.0","id":<id>,"<field>":<json>}` to one client.
    fn replyWith(b: *Broker, a: Allocator, c: *Client, id: Value, field: []const u8, json: []const u8) void {
        const id_json = std.json.Stringify.valueAlloc(a, id, .{}) catch return;
        const reply = std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"{s}\":{s}}}", .{ id_json, field, json }) catch return;
        b.toClient(c, reply);
    }

    /// The server answered the one initialize it was sent: keep a result for
    /// later clients and answer the ones that queued behind it. An error
    /// goes to them too, and the next initialize tries the server again.
    fn finishInitialize(b: *Broker, a: Allocator, msg: Value) void {
        b.init_inflight = false;
        defer b.init_waiters.clearRetainingCapacity();
        const is_result = msg.object.get("result") != null;
        const field = if (is_result) "result" else "error";
        const body = msg.object.get(field) orelse return;
        const keep = is_result and b.init_result == null; // outlives this line's arena
        const json = std.json.Stringify.valueAlloc(if (keep) b.ids_arena.allocator() else a, body, .{}) catch return;
        if (keep) b.init_result = json;
        for (b.init_waiters.items) |w| b.replyWith(a, w.client, w.id, field, json);
    }

    /// One line from a client.
    fn fromClient(b: *Broker, c: *Client, line: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }) catch return;
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        switch (classify(msg)) {
            .request => {
                const method = msg.object.get("method").?;
                const is_init = method == .string and std.mem.eql(u8, method.string, "initialize");
                if (is_init) if (b.init_result) |cached| {
                    b.replyWith(a, c, msg.object.get("id").?, "result", cached);
                    return;
                };
                const orig = cloneId(b.ids_arena.allocator(), msg.object.get("id").?) catch return;
                if (is_init and b.init_inflight) {
                    b.init_waiters.append(b.gpa, .{ .client = c, .id = orig }) catch {};
                    return;
                }
                const id = b.next_id;
                b.next_id += 1;
                if (is_init) {
                    b.init_inflight = true;
                    b.init_server_id = id;
                }
                b.pending.put(b.gpa, id, .{ .client = c, .id = orig }) catch return;
                b.toServer(withId(a, msg, .{ .integer = id }) catch return);
            },
            .notification => {
                const method = msg.object.get("method").?;
                const name = if (method == .string) method.string else "";
                if (std.mem.eql(u8, name, "notifications/initialized")) {
                    if (b.initialized_sent) return;
                    b.initialized_sent = true;
                } else if (std.mem.eql(u8, name, "notifications/cancelled")) {
                    return; // its requestId is the client's, not the server's
                }
                b.toServer(line);
            },
            else => {},
        }
    }

    /// One line from the server.
    fn fromServer(b: *Broker, line: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }) catch return;
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        switch (classify(msg)) {
            .response => {
                const idv = msg.object.get("id").?;
                if (idv != .integer) return;
                // Matched by server id: the waiters still need it if the
                // client that sent it has gone.
                if (b.init_inflight and idv.integer == b.init_server_id) b.finishInitialize(a, msg);
                const p = b.pending.fetchRemove(idv.integer) orelse return;
                b.toClient(p.value.client, withId(a, msg, p.value.id) catch return);
            },
            .notification => for (b.clients.items) |c| b.toClient(c, line),
            .request => {
                // Sampling, elicitation, roots: no single client to ask.
                const id_json = std.json.Stringify.valueAlloc(a, msg.object.get("id").?, .{}) catch return;
                const reply = std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"not available through a shared MCP server\"}}}}", .{id_json}) catch return;
                b.toServer(reply);
            },
            else => {},
        }
    }

    fn dropClient(b: *Broker, c: *Client) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        c.alive = false;
        for (b.clients.items, 0..) |x, i| if (x == c) {
            _ = b.clients.swapRemove(i);
            break;
        };
        // Its unanswered requests: the replies have nowhere to go.
        var it = b.pending.iterator();
        var stale: std.ArrayList(i64) = .empty;
        defer stale.deinit(b.gpa);
        while (it.next()) |e| if (e.value_ptr.client == c) stale.append(b.gpa, e.key_ptr.*) catch {};
        for (stale.items) |k| _ = b.pending.remove(k);
        var w: usize = 0;
        while (w < b.init_waiters.items.len) {
            if (b.init_waiters.items[w].client == c) _ = b.init_waiters.swapRemove(w) else w += 1;
        }
        if (b.clients.items.len == 0) b.last_client_left_ms = nowMs(b.io);
        c.stream.close(b.io);
    }
};

fn cloneId(a: Allocator, v: Value) !Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        else => v,
    };
}

fn nowMs(io: Io) i64 {
    return @import("util.zig").unixMs(io);
}

fn serveClient(b: *Broker, c: *Client) void {
    var rbuf: [64 * 1024]u8 = undefined;
    var r = c.stream.reader(b.io, &rbuf);
    while (true) {
        const raw = r.interface.takeDelimiterInclusive('\n') catch break;
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) continue;
        b.fromClient(c, line);
    }
    b.dropClient(c);
}

fn serveServer(b: *Broker, reader: *Io.File.Reader, done: *std.atomic.Value(bool)) void {
    while (true) {
        const raw = reader.interface.takeDelimiterInclusive('\n') catch break;
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) continue;
        b.fromServer(line);
    }
    done.store(true, .release);
}

fn acceptLoop(b: *Broker, listener: *net.Server) void {
    while (true) {
        const stream = listener.accept(b.io) catch return;
        const c = b.gpa.create(Client) catch {
            stream.close(b.io);
            continue;
        };
        c.* = .{ .stream = stream, .writer = undefined };
        c.writer = stream.writer(b.io, &c.wbuf);
        b.mutex.lockUncancelable(b.io);
        b.clients.append(b.gpa, c) catch {};
        b.mutex.unlock(b.io);
        const t = std.Thread.spawn(.{}, serveClient, .{ b, c }) catch {
            b.dropClient(c);
            continue;
        };
        t.detach();
    }
}

pub fn broker(io: Io, gpa: Allocator, a: Allocator, home: []const u8, idle_s: u32, args: []const []const u8) !void {
    if (!supported) return error.SharedMcpUnsupported;
    if (args.len < 4 or !std.mem.eql(u8, args[0], "--key") or !std.mem.eql(u8, args[2], "--")) return error.Usage;
    const path = try socketPath(a, home, args[1]);
    // One broker per socket: whoever holds the lock owns it for its lifetime.
    // A second broker (two sessions starting at once) leaves quietly instead
    // of deleting the first one's socket.
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{path});
    const lock = Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch return;
    defer lock.close(io);
    Io.Dir.cwd().deleteFile(io, path) catch {}; // a dead broker's socket
    const addr = try net.UnixAddress.init(path);
    var listener = addr.listen(io, .{}) catch return; // lost a race to another broker
    defer {
        listener.deinit(io);
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var child = try std.process.spawn(io, .{ .argv = args[3..], .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    defer @import("mcp_stdio.zig").stopChild(io, &child);
    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [1 << 20]u8 = undefined;
    var b: Broker = .{
        .io = io,
        .gpa = gpa,
        .server_in = child.stdin.?.writerStreaming(io, &in_buf),
        .ids_arena = std.heap.ArenaAllocator.init(gpa),
        .last_client_left_ms = nowMs(io),
    };
    var server_out = child.stdout.?.readerStreaming(io, &out_buf);
    var server_done = std.atomic.Value(bool).init(false);
    const st = try std.Thread.spawn(.{}, serveServer, .{ &b, &server_out, &server_done });
    st.detach();
    const at = try std.Thread.spawn(.{}, acceptLoop, .{ &b, &listener });
    at.detach();

    while (!server_done.load(.acquire)) {
        io.sleep(.fromMilliseconds(250), .awake) catch {};
        b.mutex.lockUncancelable(io);
        const idle = b.clients.items.len == 0 and nowMs(io) - b.last_client_left_ms >= @as(i64, idle_s) * 1000;
        b.mutex.unlock(io);
        if (idle) break;
    }
}

test "keyFor: same launch shares, any difference does not, env order does not matter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = struct {
        fn f(al: Allocator, s: []const u8) std.json.ObjectMap {
            return (std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable).object;
        }
    }.f;
    const one = keyFor(p(a, "{\"command\":\"uvx\",\"args\":[\"mcp-server-time\"],\"env\":{\"A\":\"1\",\"B\":\"2\"}}"));
    const same = keyFor(p(a, "{\"command\":\"uvx\",\"args\":[\"mcp-server-time\"],\"env\":{\"B\":\"2\",\"A\":\"1\"},\"shared\":true}"));
    const other_env = keyFor(p(a, "{\"command\":\"uvx\",\"args\":[\"mcp-server-time\"],\"env\":{\"A\":\"9\",\"B\":\"2\"}}"));
    const other_args = keyFor(p(a, "{\"command\":\"uvx\",\"args\":[\"mcp-server-fetch\"]}"));
    try std.testing.expectEqualSlices(u8, &one, &same);
    try std.testing.expect(!std.mem.eql(u8, &one, &other_env));
    try std.testing.expect(!std.mem.eql(u8, &one, &other_args));
}

test "classify and withId: requests get the broker's id, replies get the client's back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = try std.json.parseFromSliceLeaky(Value, a, "{\"jsonrpc\":\"2.0\",\"id\":\"c-7\",\"method\":\"tools/call\",\"params\":{\"name\":\"now\"}}", .{});
    try std.testing.expectEqual(Kind.request, classify(req));
    const out = try withId(a, req, .{ .integer = 42 });
    const back = try std.json.parseFromSliceLeaky(Value, a, out, .{});
    try std.testing.expectEqual(@as(i64, 42), back.object.get("id").?.integer);
    try std.testing.expectEqualStrings("now", back.object.get("params").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("c-7", req.object.get("id").?.string); // the original is untouched

    const resp = try std.json.parseFromSliceLeaky(Value, a, "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{}}", .{});
    try std.testing.expectEqual(Kind.response, classify(resp));
    const restored = try std.json.parseFromSliceLeaky(Value, a, try withId(a, resp, .{ .string = "c-7" }), .{});
    try std.testing.expectEqualStrings("c-7", restored.object.get("id").?.string);
    const note = try std.json.parseFromSliceLeaky(Value, a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}", .{});
    try std.testing.expectEqual(Kind.notification, classify(note));
    const srv_req = try std.json.parseFromSliceLeaky(Value, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sampling/createMessage\"}", .{});
    try std.testing.expectEqual(Kind.request, classify(srv_req));
}

test "socketPath fits the socket limit for any HOME, in a private directory" {
    if (!supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long_home = "/private/var/folders/t3/zjm3hgy56l551q_ygry8mbjm0000gn/T/graff-mcp-shared-abcdefgh/and/deeper/still";
    const p1 = try socketPath(a, long_home, "0123456789abcdef");
    try std.testing.expect(p1.len < 104); // sockaddr_un sun_path on macOS
    const p2 = try socketPath(a, "/home/other", "0123456789abcdef");
    try std.testing.expect(!std.mem.eql(u8, p1, p2)); // two homes never share a broker
    const st = try lstatOwner(try a.dupeSentinel(u8, std.fs.path.dirname(p1).?, 0));
    try std.testing.expectEqual(@as(u32, 0), st.mode & 0o077);
}

test "wantsShared: only an explicit true on a stdio entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = struct {
        fn f(al: Allocator, s: []const u8) std.json.ObjectMap {
            return (std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable).object;
        }
    }.f;
    try std.testing.expectEqual(supported, wantsShared(p(a, "{\"command\":\"uvx\",\"shared\":true}")));
    try std.testing.expect(!wantsShared(p(a, "{\"command\":\"uvx\"}")));
    try std.testing.expect(!wantsShared(p(a, "{\"url\":\"https://x/mcp\",\"shared\":true}")));
}
