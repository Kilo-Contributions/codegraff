//! Sync the user-level MCP config (`~/.codegraff/mcp.json`) between a person's
//! devices through the end-to-end encrypted vault (harness ADR 0005). The
//! whole `mcpServers` map is one static item, `graff/mcp`, keys and headers
//! included: the edge only ever holds ciphertext.
//!
//! Merging is three-way, per server name. The base is what this device last
//! synced (`~/.codegraff/mcp-sync.json`, 0600, since it holds the same
//! secrets). A server changed or removed on one side takes that side; changed
//! differently on both, this device's copy wins and the name is reported. The
//! write is a compare-and-swap on the item version, retried after a re-read.
//!
//! Harness reaches MCP servers only through graff, so a synced file reaches
//! Harness too. The session needs `HARNESS_BEARER` (Harness passes it) and a
//! device enrolled with `graff keys enable`.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Allocator = std.mem.Allocator;
const sync = @import("vault_sync.zig");
const credential_store = @import("credential_store.zig");

pub const agent = "graff";
pub const slot = "mcp";
pub const state_rel_path = ".codegraff/mcp-sync.json";

fn deepEql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| x == b.float,
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |p, q| if (!deepEql(p, q)) break :blk false;
            break :blk true;
        },
        .object => |x| objEql(x, b.object),
    };
}

fn objEql(a: ObjectMap, b: ObjectMap) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| {
        const other = b.get(e.key_ptr.*) orelse return false;
        if (!deepEql(e.value_ptr.*, other)) return false;
    }
    return true;
}

fn optEql(a: ?Value, b: ?Value) bool {
    if (a == null or b == null) return a == null and b == null;
    return deepEql(a.?, b.?);
}

pub const Merged = struct { servers: ObjectMap, conflicts: []const []const u8 };

/// Three-way merge of `mcpServers` maps, per name.
pub fn merge(a: Allocator, base: ObjectMap, local: ObjectMap, remote: ObjectMap) !Merged {
    var names: std.ArrayList([]const u8) = .empty;
    for ([_]ObjectMap{ local, remote, base }) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            for (names.items) |n| {
                if (std.mem.eql(u8, n, e.key_ptr.*)) break;
            } else try names.append(a, e.key_ptr.*);
        }
    }
    var out: ObjectMap = .empty;
    var conflicts: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        const b = base.get(name);
        const l = local.get(name);
        const r = remote.get(name);
        const pick = if (optEql(l, r)) l else if (optEql(l, b)) r else if (optEql(r, b)) l else blk: {
            try conflicts.append(a, name);
            break :blk l;
        };
        if (pick) |v| try out.put(a, name, v);
    }
    return .{ .servers = out, .conflicts = conflicts.items };
}

fn serversOf(root: Value) ObjectMap {
    if (root != .object) return .empty;
    const s = root.object.get("mcpServers") orelse return .empty;
    return if (s == .object) s.object else .empty;
}

fn parseServers(a: Allocator, bytes: []const u8) ObjectMap {
    const v = std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always }) catch return .empty;
    return serversOf(v);
}

fn render(a: Allocator, root: ObjectMap) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(a);
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try js.write(Value{ .object = root });
    try aw.writer.writeByte('\n');
    return aw.writer.buffered();
}

fn wrap(a: Allocator, servers: ObjectMap) ![]const u8 {
    var root: ObjectMap = .empty;
    try root.put(a, "mcpServers", .{ .object = servers });
    return render(a, root);
}

pub const Result = struct {
    version: u64,
    /// Names this device gained or lost from the vault.
    pulled: usize,
    /// Whether the vault item was written.
    pushed: bool,
    conflicts: []const []const u8,
};

/// Pull, merge, write the local file, push. `config_path` is the user-level
/// MCP file; `state_path` keeps the last synced version and servers.
pub fn run(io: Io, a: Allocator, s: *sync.Session, config_path: []const u8, state_path: []const u8) !Result {
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        const remote_item = try s.pull(agent, slot);
        const remote = if (remote_item) |it| parseServers(a, it.bytes) else ObjectMap.empty;
        const remote_version: u64 = if (remote_item) |it| it.version else 0;

        const base = if (Io.Dir.cwd().readFileAlloc(io, state_path, a, .limited(1 << 20))) |t| parseServers(a, t) else |_| ObjectMap.empty;
        var local_root: ObjectMap = .empty;
        if (Io.Dir.cwd().readFileAlloc(io, config_path, a, .limited(1 << 20))) |t| {
            const v = std.json.parseFromSliceLeaky(Value, a, t, .{ .allocate = .alloc_always }) catch return error.InvalidMcpConfig;
            if (v != .object) return error.InvalidMcpConfig;
            local_root = v.object;
        } else |_| {}
        const local = serversOf(.{ .object = local_root });

        const m = try merge(a, base, local, remote);
        var pulled: usize = 0;
        var it = m.servers.iterator();
        while (it.next()) |e| if (!optEql(local.get(e.key_ptr.*), e.value_ptr.*)) {
            pulled += 1;
        };
        var lit = local.iterator();
        while (lit.next()) |e| if (m.servers.get(e.key_ptr.*) == null) {
            pulled += 1;
        };

        var version = remote_version;
        const push = remote_item == null or !objEql(m.servers, remote);
        if (push) switch (try s.putAt(agent, slot, "static", remote_version, try wrap(a, m.servers))) {
            .ok => |v| version = v,
            .conflict => continue, // another device wrote first: merge again on top of it
            .lease_held => return error.LeaseHeld,
        };
        if (pulled > 0) {
            try local_root.put(a, "mcpServers", .{ .object = m.servers });
            if (std.fs.path.dirname(config_path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
            try credential_store.replaceFile(io, Io.Dir.cwd(), config_path, try render(a, local_root), credential_store.private_file);
        }
        var state: ObjectMap = .empty;
        try state.put(a, "version", .{ .integer = @intCast(version) });
        try state.put(a, "mcpServers", .{ .object = m.servers });
        if (std.fs.path.dirname(state_path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
        try credential_store.replaceFile(io, Io.Dir.cwd(), state_path, try render(a, state), credential_store.private_file);
        return .{ .version = version, .pulled = pulled, .pushed = push, .conflicts = m.conflicts };
    }
    return error.Conflict;
}

/// A vault session for this device, or why there is none.
pub fn open(io: Io, gpa: Allocator, a: Allocator, home: []const u8, env: anytype) !union(enum) { ready: *sync.Session, no_bearer, not_enrolled } {
    const client = @import("vault_client.zig");
    const keys = @import("keys_vault_cli.zig");
    const bearer = env.get("HARNESS_BEARER") orelse return .no_bearer;
    const ident = (try keys.loadIdentity(io, gpa, a, home, false, env.get("GRAFF_VAULT_DEVICE_FILE"))) orelse return .not_enrolled;
    const edge_url = env.get("HARNESS_EDGE_URL") orelse client.default_edge;
    try client.checkEdgeUrl(edge_url);
    const http = try a.create(client.Http);
    http.* = .{ .io = io, .gpa = gpa, .base = edge_url };
    const c = try a.create(client.Client);
    c.* = .{ .io = io, .arena = a, .transport = http.transport(), .bearer = bearer, .device_id = ident.id, .keys = ident.keys };
    const s = try a.create(sync.Session);
    s.* = try sync.Session.open(io, a, c);
    s.prev_key_path = try keys.prevKeyPath(a, home, env.get("GRAFF_VAULT_DEVICE_FILE"));
    return .{ .ready = s };
}

fn report(out: *Io.Writer, r: Result) !void {
    try out.print("✓ MCP servers synced (v{d}): {d} change(s) from your other devices{s}\n", .{ r.version, r.pulled, if (r.pushed) ", this device's pushed" else "" });
    for (r.conflicts) |n| try out.print("  {s} was changed on two devices; kept this device's copy\n", .{n});
}

/// `graff mcp sync`: sync ~/.codegraff/mcp.json with the vault now.
pub fn command(io: Io, gpa: Allocator, a: Allocator, home: []const u8, env: anytype, config_path: []const u8, out: *Io.Writer) !void {
    switch (try open(io, gpa, a, home, env)) {
        .no_bearer => std.process.fatal("mcp sync: needs HARNESS_BEARER (Harness passes it to graff)", .{}),
        .not_enrolled => std.process.fatal("mcp sync: this device is not enrolled; run `graff keys enable` first", .{}),
        .ready => |s| try report(out, try run(io, a, s, config_path, try std.fmt.allocPrint(a, "{s}/" ++ state_rel_path, .{home}))),
    }
}

/// After `graff mcp add --everywhere`: sync when this device can, quietly
/// skip when it is not set up, and never fail the add itself.
pub fn afterAdd(io: Io, gpa: Allocator, a: Allocator, home: []const u8, env: anytype, config_path: []const u8, out: *Io.Writer) void {
    const opened = open(io, gpa, a, home, env) catch |err| {
        out.print("  not synced to your other devices ({t}); run `graff mcp sync` later\n", .{err}) catch {};
        return;
    };
    const s = switch (opened) {
        .ready => |s| s,
        .no_bearer, .not_enrolled => return,
    };
    const r = run(io, a, s, config_path, std.fmt.allocPrint(a, "{s}/" ++ state_rel_path, .{home}) catch return) catch |err| {
        out.print("  not synced to your other devices ({t}); run `graff mcp sync` later\n", .{err}) catch {};
        return;
    };
    report(out, r) catch {};
}

const Background = struct {
    io: Io,
    home: []const u8,
    config_path: []const u8,
    vars: [3]?[]const u8,

    const names = [_][]const u8{ "HARNESS_BEARER", "GRAFF_VAULT_DEVICE_FILE", "HARNESS_EDGE_URL" };

    pub fn get(b: *const Background, name: []const u8) ?[]const u8 {
        for (names, b.vars) |n, v| if (std.mem.eql(u8, n, name)) return v;
        return null;
    }

    fn main(b: *Background) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const log = std.log.scoped(.mcp_sync);
        const s = switch (open(b.io, std.heap.smp_allocator, a, b.home, b) catch |err| return log.warn("mcp sync: {t}", .{err})) {
            .ready => |s| s,
            .no_bearer, .not_enrolled => return,
        };
        const state = std.fmt.allocPrint(a, "{s}/" ++ state_rel_path, .{b.home}) catch return;
        const r = run(b.io, a, s, b.config_path, state) catch |err| return log.warn("mcp sync: {t}", .{err});
        if (r.pulled > 0) log.info("mcp sync: {d} change(s) from your other devices (v{d})", .{ r.pulled, r.version });
    }
};

/// At session start under Harness: sync in the background, silently (ACP owns
/// stdout). Servers that arrive join through the config watcher like any other
/// edit to the user-level file. No bearer or no enrolled device: nothing runs.
pub fn startBackground(io: Io, home: []const u8, environ_map: anytype, config_path: []const u8) void {
    // GRAFF_MCP_CONFIG points somewhere else on purpose (tests, the #549 off-switch).
    if (environ_map.get("HARNESS_BEARER") == null or home.len == 0 or @import("mcp_config.zig").isEnvOverride(environ_map)) return;
    const pa = std.heap.page_allocator;
    const b = pa.create(Background) catch return;
    b.* = .{ .io = io, .home = pa.dupe(u8, home) catch return, .config_path = pa.dupe(u8, config_path) catch return, .vars = undefined };
    for (Background.names, &b.vars) |n, *v| v.* = if (environ_map.get(n)) |x| (pa.dupe(u8, x) catch return) else null;
    const t = std.Thread.spawn(.{}, Background.main, .{b}) catch return;
    t.detach();
}

test "merge takes each side's change, keeps removals, and reports a true conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = parseServers(a,
        \\{"mcpServers":{"keep":{"url":"https://k"},"gone-here":{"url":"https://g"},"gone-there":{"url":"https://t"},"both":{"url":"https://b0"}}}
    );
    const local = parseServers(a,
        \\{"mcpServers":{"keep":{"url":"https://k"},"gone-there":{"url":"https://t"},"new-here":{"url":"https://n"},"both":{"url":"https://b1"}}}
    );
    const remote = parseServers(a,
        \\{"mcpServers":{"keep":{"url":"https://k"},"gone-here":{"url":"https://g"},"new-there":{"command":"npx","args":["-y","x"]},"both":{"url":"https://b2"}}}
    );
    const m = try merge(a, base, local, remote);
    try std.testing.expect(m.servers.get("keep") != null);
    try std.testing.expect(m.servers.get("gone-here") == null);
    try std.testing.expect(m.servers.get("gone-there") == null);
    try std.testing.expect(m.servers.get("new-here") != null);
    try std.testing.expect(m.servers.get("new-there") != null);
    try std.testing.expectEqualStrings("https://b1", m.servers.get("both").?.object.get("url").?.string);
    try std.testing.expectEqual(@as(usize, 1), m.conflicts.len);
    try std.testing.expectEqualStrings("both", m.conflicts[0]);
}

test "two devices converge through the vault, removals included" {
    const crypto = @import("vault_crypto.zig");
    const client = @import("vault_client.zig");
    const MockEdge = @import("vault_mock_edge.zig").MockEdge;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    var edge = MockEdge.init(std.testing.allocator);
    defer edge.deinit();

    const Dev = struct { c: client.Client, s: sync.Session, cfg: []const u8, state: []const u8 };
    var devs: [2]Dev = undefined;
    for (&devs, [_][]const u8{ "dev-a", "dev-b" }) |*d, id| {
        d.c = .{ .io = io, .arena = a, .transport = edge.transport(), .bearer = "user-7", .device_id = id, .keys = crypto.DeviceKeys.generate(io), .now_ms = 1_700_000_000_000 };
        d.s = try sync.Session.open(io, a, &d.c);
        d.cfg = try std.fmt.allocPrint(a, "{s}/{s}/mcp.json", .{ root, id });
        d.state = try std.fmt.allocPrint(a, "{s}/{s}/mcp-sync.json", .{ root, id });
    }
    _ = try devs[0].s.enable("laptop");
    _ = try devs[1].s.enable("desktop");
    try devs[0].s.approve("dev-b");

    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(devs[0].cfg).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = devs[0].cfg, .data = "{\"mcpServers\":{\"linear\":{\"url\":\"https://mcp.linear.app/mcp\"}},\"other\":1}" });
    const first = try run(io, a, &devs[0].s, devs[0].cfg, devs[0].state);
    try std.testing.expect(first.pushed);

    // The second device has nothing yet: it pulls linear and pushes nothing.
    const second = try run(io, a, &devs[1].s, devs[1].cfg, devs[1].state);
    try std.testing.expectEqual(@as(usize, 1), second.pulled);
    try std.testing.expect(!second.pushed);
    const b_text = try Io.Dir.cwd().readFileAlloc(io, devs[1].cfg, a, .limited(1 << 16));
    try std.testing.expect(parseServers(a, b_text).get("linear") != null);

    // Removing it on the second device removes it on the first, and the
    // first device's unrelated top-level keys survive.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = devs[1].cfg, .data = "{\"mcpServers\":{}}" });
    _ = try run(io, a, &devs[1].s, devs[1].cfg, devs[1].state);
    const again = try run(io, a, &devs[0].s, devs[0].cfg, devs[0].state);
    try std.testing.expectEqual(@as(usize, 1), again.pulled);
    const a_text = try Io.Dir.cwd().readFileAlloc(io, devs[0].cfg, a, .limited(1 << 16));
    try std.testing.expect(parseServers(a, a_text).get("linear") == null);
    try std.testing.expect(std.mem.indexOf(u8, a_text, "\"other\"") != null);
}
