//! `graff mcp add <anything>`: infer an entry from a URL, an npm/uvx package, or
//! a pasted Claude/Cursor/VS Code JSON snippet, then verify it connects.
//!
//! The explicit forms (`add <name> --url …`, `add <name> -- <command> …`) stay
//! in mcp_cli.zig; this module only decides what an unlabeled argument means
//! and checks the saved entry by connecting to it and listing its tools.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// One server to save: the name and its `.mcp.json` entry
/// (`command`/`args`/`env` or `url`/`headers`).
pub const Named = struct { name: []const u8, cfg: std.json.ObjectMap };

fn lowerSlug(a: Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |c| {
        const l = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(l)) {
            try out.append(a, l);
        } else if ((l == '-' or l == '_' or l == '.') and out.items.len > 0 and out.items[out.items.len - 1] != '-') {
            try out.append(a, '-');
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') out.items.len -= 1;
    return out.items;
}

pub fn isUrl(token: []const u8) bool {
    return std.mem.startsWith(u8, token, "https://") or std.mem.startsWith(u8, token, "http://");
}

/// `https://mcp.linear.app/sse` → "linear"; `http://localhost:8931/mcp` → "local-8931".
pub fn nameFromUrl(a: Allocator, url: []const u8) ![]const u8 {
    const after = url[(std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl) + 3 ..];
    const authority = after[0 .. std.mem.indexOfAny(u8, after, "/?#") orelse after.len];
    const host_start = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| at + 1 else 0;
    const host_port = authority[host_start..];
    const bracketed = std.mem.startsWith(u8, host_port, "[");
    const colon = if (bracketed) std.mem.indexOf(u8, host_port, "]:") else std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |c| host_port[0 .. c + @intFromBool(bracketed)] else host_port;
    const port = if (colon) |c| host_port[c + 1 + @intFromBool(bracketed) ..] else "";
    if (std.mem.eql(u8, host, "localhost") or std.mem.startsWith(u8, host, "127.") or std.mem.eql(u8, host, "[::1]"))
        return if (port.len > 0) std.fmt.allocPrint(a, "local-{s}", .{port}) else "local";
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (labels.peek() == null) break; // never the TLD
        const generic = [_][]const u8{ "mcp", "api", "www", "server", "app", "remote" };
        const skip = for (generic) |g| {
            if (std.ascii.eqlIgnoreCase(label, g)) break true;
        } else false;
        if (!skip) return lowerSlug(a, label);
    }
    return lowerSlug(a, host);
}

pub const Runner = enum { npx, uvx };
pub const Package = struct { runner: Runner, pkg: []const u8 };

/// An npm package (`@scope/name`, a bare `*mcp*` name, or `npx:name`), or a
/// Python one with an explicit `uvx:` prefix. Paths and plain commands are not.
pub fn packageSpec(token: []const u8) ?Package {
    if (std.mem.startsWith(u8, token, "uvx:")) return if (token.len > 4) .{ .runner = .uvx, .pkg = token[4..] } else null;
    if (std.mem.startsWith(u8, token, "npx:")) return if (token.len > 4) .{ .runner = .npx, .pkg = token[4..] } else null;
    if (token.len > 2 and token[0] == '@' and std.mem.indexOfScalar(u8, token, '/') != null and std.mem.indexOfAny(u8, token, " \\") == null)
        return .{ .runner = .npx, .pkg = token };
    if (std.mem.indexOf(u8, token, "mcp") == null) return null;
    for (token) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '.' or c == '_' or c == '@')) return null;
    return .{ .runner = .npx, .pkg = token };
}

/// `@modelcontextprotocol/server-github` → "github", `@playwright/mcp` →
/// "playwright", `@upstash/context7-mcp@latest` → "context7".
pub fn nameFromPackage(a: Allocator, pkg: []const u8) ![]const u8 {
    var body = pkg;
    // A version pin: the last '@' past the scope marker.
    if (std.mem.lastIndexOfScalar(u8, body, '@')) |at| if (at > 0) {
        body = body[0..at];
    };
    const slash = std.mem.lastIndexOfScalar(u8, body, '/');
    var seg = if (slash) |s| body[s + 1 ..] else body;
    const scope = if (slash) |s| std.mem.trimStart(u8, body[0..s], "@") else "";
    for ([_][]const u8{ "mcp-server-", "server-", "mcp-" }) |p| if (std.mem.startsWith(u8, seg, p) and seg.len > p.len) {
        seg = seg[p.len..];
        break;
    };
    for ([_][]const u8{ "-mcp-server", "-server-mcp", "-mcp", "-server" }) |s| if (std.mem.endsWith(u8, seg, s) and seg.len > s.len) {
        seg = seg[0 .. seg.len - s.len];
        break;
    };
    if ((std.mem.eql(u8, seg, "mcp") or std.mem.eql(u8, seg, "server")) and scope.len > 0) seg = scope;
    return lowerSlug(a, seg);
}

fn putStrings(a: Allocator, cfg: *std.json.ObjectMap, key: []const u8, items: []const []const u8) !void {
    var arr = std.json.Array.init(a);
    for (items) |s| try arr.append(.{ .string = s });
    try cfg.put(a, key, .{ .array = arr });
}

/// The entry for one unlabeled token (URL or package), or null when the token
/// is neither: the caller then treats it as an explicit command.
pub fn infer(a: Allocator, token: []const u8, name_override: ?[]const u8) !?Named {
    var cfg: std.json.ObjectMap = .empty;
    if (isUrl(token)) {
        try cfg.put(a, "url", .{ .string = token });
        return .{ .name = name_override orelse try nameFromUrl(a, token), .cfg = cfg };
    }
    const spec = packageSpec(token) orelse return null;
    switch (spec.runner) {
        .npx => {
            try cfg.put(a, "command", .{ .string = "npx" });
            try putStrings(a, &cfg, "args", &.{ "-y", spec.pkg });
        },
        .uvx => {
            try cfg.put(a, "command", .{ .string = "uvx" });
            try putStrings(a, &cfg, "args", &.{spec.pkg});
        },
    }
    return .{ .name = name_override orelse try nameFromPackage(a, spec.pkg), .cfg = cfg };
}

/// Keep only what graff's config reads; map the URL spellings other clients use.
pub fn normalize(a: Allocator, raw: Value) !std.json.ObjectMap {
    if (raw != .object) return error.UnsupportedEntry;
    var cfg: std.json.ObjectMap = .empty;
    const o = raw.object;
    if (o.get("command")) |c| {
        if (c != .string) return error.UnsupportedEntry;
        try cfg.put(a, "command", c);
        if (o.get("args")) |args| {
            if (args != .array) return error.UnsupportedEntry;
            for (args.array.items) |arg| if (arg != .string) return error.UnsupportedEntry;
            try cfg.put(a, "args", args);
        }
        if (o.get("env")) |env| if (env == .object) try cfg.put(a, "env", env);
        return cfg;
    }
    for ([_][]const u8{ "url", "serverUrl", "httpUrl" }) |key| if (o.get(key)) |u| if (u == .string) {
        try cfg.put(a, "url", u);
        if (o.get("headers")) |h| if (h == .object) try cfg.put(a, "headers", h);
        return cfg;
    };
    return error.UnsupportedEntry;
}

fn isEntry(v: Value) bool {
    return v == .object and (v.object.get("command") != null or v.object.get("url") != null or v.object.get("serverUrl") != null or v.object.get("httpUrl") != null);
}

/// Servers in a pasted snippet: `{"mcpServers":{…}}` (Claude, Cursor),
/// `{"servers":{…}}` or `{"mcp":{"servers":{…}}}` (VS Code), a bare
/// `{name: entry}` map, or one entry (named by `name_override` or its URL).
pub fn fromJson(a: Allocator, text: []const u8, name_override: ?[]const u8) ![]Named {
    const root = std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always }) catch return error.InvalidJson;
    if (root != .object) return error.InvalidJson;
    var out: std.ArrayList(Named) = .empty;
    if (isEntry(root)) {
        const cfg = try normalize(a, root);
        const name = name_override orelse blk: {
            if (cfg.get("url")) |u| break :blk try nameFromUrl(a, u.string);
            if (cfg.get("args")) |args| for (args.array.items) |arg| if (packageSpec(arg.string)) |p| break :blk try nameFromPackage(a, p.pkg);
            return error.NameRequired;
        };
        try out.append(a, .{ .name = name, .cfg = cfg });
        return out.items;
    }
    const map = if (root.object.get("mcpServers")) |m| m else if (root.object.get("servers")) |m| m else if (root.object.get("mcp")) |m|
        (if (m == .object) (m.object.get("servers") orelse return error.NoServers) else return error.NoServers)
    else
        root;
    if (map != .object) return error.NoServers;
    var it = map.object.iterator();
    while (it.next()) |e| {
        if (!isEntry(e.value_ptr.*)) continue;
        try out.append(a, .{ .name = try lowerSlug(a, e.key_ptr.*), .cfg = try normalize(a, e.value_ptr.*) });
    }
    if (out.items.len == 0) return error.NoServers;
    return out.items;
}

pub const Checked = union(enum) {
    ok: struct { tools: usize, sample: []const u8 },
    needs_login,
    failed: anyerror,
};

/// Connect to one saved entry, list its tools, and disconnect.
pub fn verify(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, entry: Named) Checked {
    const mcp = @import("mcp.zig");
    const rpc = @import("mcp_rpc.zig");
    // A first `npx -y` or `uvx` run downloads the package before it can answer.
    const saved_timeout = rpc.stdio_handshake_timeout_ms;
    rpc.stdio_handshake_timeout_ms = @max(saved_timeout, 120_000);
    defer rpc.stdio_handshake_timeout_ms = saved_timeout;
    var reg = mcp.Registry.emptyWithOAuthHome(gpa, io, home);
    defer reg.deinit();
    const a = reg.arena();
    var servers: std.ArrayList(*rpc.Server) = .empty;
    var tools: std.ArrayList(mcp.Tool) = .empty;
    reg.startServer(a, &servers, &tools, entry.name, entry.cfg) catch |err| {
        reg.servers = servers.items;
        return if (err == error.McpAuthenticationRequired) .needs_login else .{ .failed = err };
    };
    reg.servers = servers.items;
    reg.tools = tools.items;
    var sample: std.ArrayList(u8) = .empty;
    for (tools.items, 0..) |t, i| {
        if (i == 5) {
            sample.appendSlice(arena, ", …") catch break;
            break;
        }
        if (i > 0) sample.appendSlice(arena, ", ") catch break;
        sample.appendSlice(arena, t.original_name) catch break;
    }
    return .{ .ok = .{ .tools = tools.items.len, .sample = sample.items } };
}

/// One line a person can act on for a failed connection.
pub fn failureHint(err: anyerror, cfg: std.json.ObjectMap) []const u8 {
    const command = if (cfg.get("command")) |c| (if (c == .string) c.string else "") else "";
    return switch (err) {
        error.FileNotFound => if (std.mem.eql(u8, command, "npx"))
            "`npx` was not found; install Node.js, or add the server with an explicit command"
        else if (std.mem.eql(u8, command, "uvx"))
            "`uvx` was not found; install uv, or add the server with an explicit command"
        else
            "the command was not found on PATH",
        error.BadMcpUrl => "the URL must use HTTPS (HTTP only for localhost)",
        error.EndOfStream, error.BrokenPipe => "the server exited during startup; it may need an environment variable (`--env KEY=VALUE`) or a different package (`uvx:` for Python servers)",
        else => "the server did not complete the MCP handshake",
    };
}

test "names come from the host or the package, not boilerplate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("linear", try nameFromUrl(a, "https://mcp.linear.app/sse"));
    try std.testing.expectEqualStrings("mobbin", try nameFromUrl(a, "https://api.mobbin.com/mcp"));
    try std.testing.expectEqualStrings("local-8931", try nameFromUrl(a, "http://localhost:8931/mcp"));
    try std.testing.expectEqualStrings("example", try nameFromUrl(a, "https://user@example.com:8443/x"));
    try std.testing.expectEqualStrings("github", try nameFromPackage(a, "@modelcontextprotocol/server-github"));
    try std.testing.expectEqualStrings("playwright", try nameFromPackage(a, "@playwright/mcp"));
    try std.testing.expectEqualStrings("context7", try nameFromPackage(a, "@upstash/context7-mcp@latest"));
    try std.testing.expectEqualStrings("fetch", try nameFromPackage(a, "mcp-server-fetch"));
}

test "infer maps URLs and packages; other tokens stay commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = (try infer(a, "https://mcp.linear.app/sse", null)).?;
    try std.testing.expectEqualStrings("https://mcp.linear.app/sse", url.cfg.get("url").?.string);
    const npm = (try infer(a, "@playwright/mcp", null)).?;
    try std.testing.expectEqualStrings("npx", npm.cfg.get("command").?.string);
    try std.testing.expectEqualStrings("-y", npm.cfg.get("args").?.array.items[0].string);
    const py = (try infer(a, "uvx:mcp-server-fetch", "fetch")).?;
    try std.testing.expectEqualStrings("uvx", py.cfg.get("command").?.string);
    try std.testing.expectEqualStrings("fetch", py.name);
    try std.testing.expect((try infer(a, "node", null)) == null);
    try std.testing.expect((try infer(a, "./server.js", null)) == null);
}

test "fromJson reads Claude, VS Code, bare-map, and single-entry snippets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const claude = try fromJson(a,
        \\{"mcpServers":{"Sentry":{"command":"npx","args":["-y","@sentry/mcp-server"],"env":{"TOKEN":"x"}},"linear":{"url":"https://mcp.linear.app/sse"}}}
    , null);
    try std.testing.expectEqual(@as(usize, 2), claude.len);
    var saw_sentry_env = false;
    for (claude) |n| if (std.mem.eql(u8, n.name, "sentry")) {
        saw_sentry_env = n.cfg.get("env") != null;
    };
    try std.testing.expect(saw_sentry_env);
    const vscode = try fromJson(a,
        \\{"mcp":{"servers":{"gh":{"type":"http","url":"https://api.githubcopilot.com/mcp/"}}}}
    , null);
    try std.testing.expectEqualStrings("https://api.githubcopilot.com/mcp/", vscode[0].cfg.get("url").?.string);
    try std.testing.expect(vscode[0].cfg.get("type") == null);
    const windsurf = try fromJson(a,
        \\{"deepwiki":{"serverUrl":"https://mcp.deepwiki.com/mcp"}}
    , null);
    try std.testing.expectEqualStrings("https://mcp.deepwiki.com/mcp", windsurf[0].cfg.get("url").?.string);
    const single = try fromJson(a,
        \\{"command":"npx","args":["-y","@upstash/context7-mcp"]}
    , null);
    try std.testing.expectEqualStrings("context7", single[0].name);
    try std.testing.expectError(error.NoServers, fromJson(a, "{\"x\":1}", null));
}
