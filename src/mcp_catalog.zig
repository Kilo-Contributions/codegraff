//! `graff mcp add <name>`: resolve a bare server name to a `.mcp.json` entry.
//!
//! The curated list codegraff.com/mcp publishes as JSON is asked first; every
//! entry there was connected with graff before it was listed. A name it does
//! not know goes to the official MCP registry, where only a publisher that owns
//! the name is picked automatically: a verified domain namespace (`com.stripe`)
//! or GitHub account (`io.github.stripe`) whose label equals it. Anyone can
//! publish `io.github.someone/stripe-mcp`, so a match on the server's own name
//! is listed for the person to choose, never run.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const default_catalog_url = "https://codegraff.com/mcp.json";
pub const default_registry_url = "https://registry.modelcontextprotocol.io/v0.1/servers";

/// Something a person must supply before the entry can work: an environment
/// variable for a local server, or a request header for a hosted one.
pub const Need = struct {
    env: ?[]const u8 = null,
    header: ?[]const u8 = null,
    prefix: []const u8 = "",
    hint: []const u8 = "",
};

pub const Found = struct {
    name: []const u8,
    title: []const u8,
    cfg: std.json.ObjectMap,
    needs: []const Need = &.{},
    limitation: ?[]const u8 = null,
    /// Where it came from, for the line graff prints before saving.
    source: []const u8,
};

pub const Lookup = union(enum) {
    found: Found,
    /// Registry servers with the name that graff will not pick on its own.
    candidates: []const []const u8,
    not_found,
};

/// A server name as someone would type it: `linear`, `brave-search`. Not a
/// URL, a scoped package, a path, or a `uvx:` spec.
pub fn isBareName(token: []const u8) bool {
    if (token.len == 0 or token.len > 64 or !std.ascii.isAlphanumeric(token[0])) return false;
    for (token) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn eqlLower(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The curated entry for `query` (its slug or an alias).
pub fn fromCatalog(a: Allocator, root: Value, query: []const u8) !?Found {
    if (root != .object) return error.BadCatalog;
    const servers = root.object.get("servers") orelse return error.BadCatalog;
    if (servers != .array) return error.BadCatalog;
    for (servers.array.items) |s| {
        if (s != .object) continue;
        const slug = str(s.object, "slug") orelse continue;
        var hit = eqlLower(slug, query);
        if (!hit) if (s.object.get("aliases")) |al| if (al == .array) for (al.array.items) |x| {
            if (x == .string and eqlLower(x.string, query)) hit = true;
        };
        if (!hit) continue;
        const raw = s.object.get("config") orelse return error.BadCatalog;
        var needs: std.ArrayList(Need) = .empty;
        if (s.object.get("needs")) |ns| if (ns == .array) for (ns.array.items) |n| {
            if (n != .object) continue;
            try needs.append(a, .{
                .env = str(n.object, "env"),
                .header = str(n.object, "header"),
                .prefix = str(n.object, "prefix") orelse "",
                .hint = str(n.object, "hint") orelse "",
            });
        };
        return .{
            .name = slug,
            .title = str(s.object, "name") orelse slug,
            .cfg = try @import("mcp_add.zig").normalize(a, raw),
            .needs = needs.items,
            .limitation = str(s.object, "limitation"),
            .source = "codegraff.com/mcp",
        };
    }
    return null;
}

/// Who published a registry server: `com.stripe/mcp` → "stripe",
/// `io.github.getsentry/sentry-mcp` → "getsentry".
pub fn ownerOf(server_name: []const u8) []const u8 {
    const ns = server_name[0 .. std.mem.indexOfScalar(u8, server_name, '/') orelse server_name.len];
    if (std.mem.startsWith(u8, ns, "io.github.")) return ns["io.github.".len..];
    var labels = std.mem.splitScalar(u8, ns, '.');
    _ = labels.next();
    return labels.next() orelse ns;
}

fn leafOf(server_name: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, server_name, '/') orelse return server_name;
    return server_name[slash + 1 ..];
}

fn putArgs(a: Allocator, cfg: *std.json.ObjectMap, command: []const u8, args: []const []const u8) !void {
    try cfg.put(a, "command", .{ .string = command });
    var arr = std.json.Array.init(a);
    for (args) |s| try arr.append(.{ .string = s });
    try cfg.put(a, "args", .{ .array = arr });
}

fn required(v: Value) bool {
    if (v != .object) return false;
    const r = v.object.get("isRequired") orelse return false;
    return r == .bool and r.bool;
}

/// A `.mcp.json` entry graff can run for one registry server: a Streamable
/// HTTP remote first, else an npm or PyPI stdio package pinned to its version.
fn registryEntry(a: Allocator, server: std.json.ObjectMap) !?struct { cfg: std.json.ObjectMap, needs: []const Need } {
    var needs: std.ArrayList(Need) = .empty;
    var cfg: std.json.ObjectMap = .empty;
    if (server.get("remotes")) |remotes| if (remotes == .array) for (remotes.array.items) |r| {
        if (r != .object) continue;
        const kind = str(r.object, "type") orelse continue;
        const url = str(r.object, "url") orelse continue;
        if (!std.mem.eql(u8, kind, "streamable-http") or std.mem.indexOfScalar(u8, url, '{') != null) continue;
        try cfg.put(a, "url", .{ .string = url });
        if (r.object.get("headers")) |hs| if (hs == .array) for (hs.array.items) |h| if (required(h)) {
            try needs.append(a, .{ .header = str(h.object, "name"), .hint = str(h.object, "description") orelse "" });
        };
        return .{ .cfg = cfg, .needs = needs.items };
    };
    if (server.get("packages")) |pkgs| if (pkgs == .array) for (pkgs.array.items) |p| {
        if (p != .object) continue;
        const reg_type = str(p.object, "registryType") orelse continue;
        const id = str(p.object, "identifier") orelse continue;
        if (p.object.get("transport")) |t| if (t == .object) if (str(t.object, "type")) |tt| if (!std.mem.eql(u8, tt, "stdio")) continue;
        const needs_args = if (p.object.get("packageArguments")) |pa| blk: {
            if (pa == .array) for (pa.array.items) |x| if (required(x)) break :blk true;
            break :blk false;
        } else false;
        if (needs_args) continue;
        const pinned = if (str(p.object, "version")) |v| try std.fmt.allocPrint(a, "{s}@{s}", .{ id, v }) else id;
        if (std.mem.eql(u8, reg_type, "npm")) {
            try putArgs(a, &cfg, "npx", &.{ "-y", pinned });
        } else if (std.mem.eql(u8, reg_type, "pypi")) {
            try putArgs(a, &cfg, "uvx", &.{pinned});
        } else continue;
        if (p.object.get("environmentVariables")) |envs| if (envs == .array) for (envs.array.items) |e| if (required(e)) {
            try needs.append(a, .{ .env = str(e.object, "name"), .hint = str(e.object, "description") orelse "" });
        };
        return .{ .cfg = cfg, .needs = needs.items };
    };
    return null;
}

/// Pick from a registry search response (`{"servers":[{"server":{…}}]}`).
pub fn fromRegistry(a: Allocator, root: Value, query: []const u8) !Lookup {
    if (root != .object) return error.BadRegistry;
    const list = root.object.get("servers") orelse return error.BadRegistry;
    if (list != .array) return error.BadRegistry;
    var owned: std.ArrayList(Found) = .empty;
    // Not picked, only listed: publishers whose account contains the name
    // (`getsentry` for sentry) ahead of servers that merely mention it.
    var close: std.ArrayList([]const u8) = .empty;
    var others: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const sv = item.object.get("server") orelse continue;
        if (sv != .object) continue;
        const name = str(sv.object, "name") orelse continue;
        if (item.object.get("_meta")) |meta| if (meta == .object) if (meta.object.get("io.modelcontextprotocol.registry/official")) |off| if (off == .object) {
            if (off.object.get("isLatest")) |l| if (l == .bool and !l.bool) continue;
            if (str(off.object, "status")) |st| if (!std.mem.eql(u8, st, "active")) continue;
        };
        const entry = if (eqlLower(ownerOf(name), query)) try registryEntry(a, sv.object) else null;
        if (entry) |e| {
            try owned.append(a, .{ .name = try a.dupe(u8, query), .title = name, .cfg = e.cfg, .needs = e.needs, .source = "the MCP registry" });
        } else if (std.ascii.findIgnoreCase(ownerOf(name), query) != null) {
            try close.append(a, name);
        } else if (std.ascii.findIgnoreCase(leafOf(name), query) != null or std.ascii.findIgnoreCase(str(sv.object, "title") orelse "", query) != null) {
            try others.append(a, name);
        }
    }
    if (owned.items.len == 1) return .{ .found = owned.items[0] };
    if (owned.items.len > 1) {
        // One publisher, several servers: the one named for the product, or
        // its generic `/mcp`, else let the person choose.
        for ([_][]const u8{ query, "mcp" }) |want| for (owned.items) |f| {
            if (eqlLower(leafOf(f.title), want)) return .{ .found = f };
        };
        for (owned.items) |f| try close.append(a, f.title);
    }
    try close.appendSlice(a, others.items);
    return if (close.items.len > 0) .{ .candidates = close.items[0..@min(close.items.len, 6)] } else .not_found;
}

fn fetchJson(io: Io, gpa: Allocator, arena: Allocator, url: []const u8) !Value {
    if (!std.mem.startsWith(u8, url, "https://") and !@import("mcp.zig").validRemoteUrl(url)) return error.InsecureUrl;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body: Io.Writer.Allocating = .init(arena);
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "graff-mcp-add" },
    };
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
        .extra_headers = &headers,
    });
    if (@intFromEnum(res.status) < 200 or @intFromEnum(res.status) >= 300) return error.HttpFailure;
    return std.json.parseFromSliceLeaky(Value, arena, body.writer.buffered(), .{ .allocate = .alloc_always });
}

/// The curated entry, or null when the catalog is unreachable or lacks it.
pub fn lookupCatalog(io: Io, gpa: Allocator, arena: Allocator, catalog_url: []const u8, query: []const u8) ?Found {
    if (catalog_url.len == 0) return null;
    const root = fetchJson(io, gpa, arena, catalog_url) catch return null;
    return fromCatalog(arena, root, query) catch null;
}

pub fn lookupRegistry(io: Io, gpa: Allocator, arena: Allocator, registry_url: []const u8, query: []const u8) !Lookup {
    if (registry_url.len == 0) return .not_found;
    const url = try std.fmt.allocPrint(arena, "{s}?search={s}&version=latest&limit=100", .{ registry_url, query });
    return fromRegistry(arena, try fetchJson(io, gpa, arena, url), query);
}

pub const Pair = struct { key: []const u8, value: []const u8 };
pub const Given = struct { env: []const Pair = &.{}, headers: []const Pair = &.{} };

/// What follows `add <name>`: only `--env K=V` and `--header K=V` pairs, or
/// null so the caller parses an explicit form (`-- <command>`, `--url`).
pub fn parseGiven(a: Allocator, rest: []const []const u8) !?Given {
    var env: std.ArrayList(Pair) = .empty;
    var headers: std.ArrayList(Pair) = .empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        var flag: []const u8 = "";
        var inline_value: ?[]const u8 = null;
        for ([_][]const u8{ "--env", "--header" }) |f| {
            if (std.mem.eql(u8, rest[i], f)) {
                flag = f;
            } else if (std.mem.startsWith(u8, rest[i], f) and rest[i].len > f.len and rest[i][f.len] == '=') {
                flag = f;
                inline_value = rest[i][f.len + 1 ..];
            } else continue;
            break;
        }
        if (flag.len == 0) return null;
        const kv = inline_value orelse blk: {
            i += 1;
            if (i >= rest.len) return null;
            break :blk rest[i];
        };
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return null;
        const pair: Pair = .{ .key = kv[0..eq], .value = kv[eq + 1 ..] };
        try (if (std.mem.eql(u8, flag, "--env")) &env else &headers).append(a, pair);
    }
    return .{ .env = env.items, .headers = headers.items };
}

fn find(pairs: []const Pair, key: []const u8) ?[]const u8 {
    for (pairs) |p| if (std.ascii.eqlIgnoreCase(p.key, key)) return p.value;
    return null;
}

fn putPairs(a: Allocator, cfg: *std.json.ObjectMap, field: []const u8, pairs: []const Pair) !void {
    if (pairs.len == 0) return;
    var obj: std.json.ObjectMap = if (cfg.get(field)) |v| (if (v == .object) v.object else .empty) else .empty;
    for (pairs) |p| try obj.put(a, p.key, .{ .string = p.value });
    try cfg.put(a, field, .{ .object = obj });
}

/// Resolve `query` and fold in what the person gave: the curated list, then a
/// bare `*mcp*` npm name, then the registry. Prints where the entry came from;
/// exits with the reason when it cannot be saved as it stands.
pub fn resolve(io: Io, gpa: Allocator, a: Allocator, environ_map: anytype, query: []const u8, name_override: ?[]const u8, given: Given, out: *Io.Writer) !@import("mcp_add.zig").Named {
    const add = @import("mcp_add.zig");
    const catalog_url = environ_map.get("GRAFF_MCP_CATALOG_URL") orelse default_catalog_url;
    const registry_url = environ_map.get("GRAFF_MCP_REGISTRY_URL") orelse default_registry_url;
    var found = lookupCatalog(io, gpa, a, catalog_url, query) orelse blk: {
        if (try add.infer(a, query, name_override)) |pkg| break :blk Found{ .name = pkg.name, .title = query, .cfg = pkg.cfg, .source = "npm" };
        const result = lookupRegistry(io, gpa, a, registry_url, query) catch |err|
            std.process.fatal("mcp add: '{s}' is not on codegraff.com/mcp, and the MCP registry could not be reached ({t}). Give its URL or package instead.", .{ query, err });
        switch (result) {
            .found => |f| break :blk f,
            .not_found => std.process.fatal("mcp add: no MCP server named '{s}' on codegraff.com/mcp or in the MCP registry. Give its URL, an npm package (@scope/name), or uvx:<python-package>.", .{query}),
            .candidates => |names| {
                var list: Io.Writer.Allocating = .init(a);
                for (names) |n| try list.writer.print("\n  {s}", .{n});
                std.process.fatal("mcp add: '{s}' is not on codegraff.com/mcp, and no registry publisher owns that name, so graff will not pick one. Registry servers that mention it:{s}\nCheck one at registry.modelcontextprotocol.io, then add it by its URL or package.", .{ query, list.writer.buffered() });
            },
        }
    };
    if (found.limitation) |why| std.process.fatal("mcp add: {s}: {s}", .{ found.title, why });
    const hosted = found.cfg.get("url") != null;
    if (given.env.len > 0 and hosted) std.process.fatal("mcp add: {s} is a hosted server; pass credentials with --header, not --env", .{found.title});
    if (given.headers.len > 0 and !hosted) std.process.fatal("mcp add: {s} runs locally; pass credentials with --env, not --header", .{found.title});

    var headers: std.ArrayList(Pair) = .empty;
    for (given.headers) |h| try headers.append(a, h);
    var missing: Io.Writer.Allocating = .init(a);
    var retry: Io.Writer.Allocating = .init(a);
    for (found.needs) |need| {
        if (need.env) |key| {
            if (find(given.env, key) != null) continue;
            if (environ_map.get(key) != null) {
                try out.print("  using {s} from your environment\n", .{key});
                continue;
            }
            try missing.writer.print("\n  {s}: {s}", .{ key, need.hint });
            try retry.writer.print(" --env {s}=…", .{key});
        } else if (need.header) |key| {
            if (find(headers.items, key)) |value| {
                // A bare token for an `Authorization: Bearer` header gets its scheme.
                if (need.prefix.len > 0 and !std.ascii.startsWithIgnoreCase(value, need.prefix)) {
                    for (headers.items) |*h| if (std.ascii.eqlIgnoreCase(h.key, key)) {
                        h.value = try std.fmt.allocPrint(a, "{s}{s}", .{ need.prefix, value });
                    };
                }
                continue;
            }
            try missing.writer.print("\n  {s} header: {s}", .{ key, need.hint });
            try retry.writer.print(" --header \"{s}={s}…\"", .{ key, need.prefix });
        }
    }
    if (missing.writer.buffered().len > 0)
        std.process.fatal("mcp add: {s} needs{s}\nnothing was saved; run `graff mcp add {s}{s}`", .{ found.title, missing.writer.buffered(), query, retry.writer.buffered() });
    try putPairs(a, &found.cfg, "env", given.env);
    try putPairs(a, &found.cfg, "headers", headers.items);
    if (!std.mem.eql(u8, found.source, "npm")) try out.print("  found {s} via {s}\n", .{ found.title, found.source });
    return .{ .name = name_override orelse found.name, .cfg = found.cfg };
}

test "parseGiven accepts only credential pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = (try parseGiven(a, &.{ "--env", "K=V", "--header=Authorization=Bearer x" })).?;
    try std.testing.expectEqualStrings("V", g.env[0].value);
    try std.testing.expectEqualStrings("Bearer x", g.headers[0].value);
    try std.testing.expect((try parseGiven(a, &.{ "--", "node", "x.js" })) == null);
    try std.testing.expect((try parseGiven(a, &.{"--url"})) == null);
    try std.testing.expect((try parseGiven(a, &.{ "--env", "NOEQUALS" })) == null);
    try std.testing.expectEqual(@as(usize, 0), (try parseGiven(a, &.{})).?.env.len);
}

test "bare names are words, not URLs, packages, or paths" {
    try std.testing.expect(isBareName("linear"));
    try std.testing.expect(isBareName("brave-search"));
    try std.testing.expect(!isBareName("@playwright/mcp"));
    try std.testing.expect(!isBareName("uvx:mcp-server-fetch"));
    try std.testing.expect(!isBareName("https://mcp.linear.app/mcp"));
    try std.testing.expect(!isBareName("./server.js"));
    try std.testing.expect(!isBareName("-x"));
}

test "fromCatalog matches a slug or an alias and carries needs and limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(Value, a,
        \\{"version":1,"servers":[
        \\ {"slug":"linear","name":"Linear","config":{"url":"https://mcp.linear.app/mcp"}},
        \\ {"slug":"brave-search","name":"Brave Search","aliases":["brave"],"config":{"command":"npx","args":["-y","@brave/brave-search-mcp-server"]},
        \\  "needs":[{"env":"BRAVE_API_KEY","hint":"an API key"}]},
        \\ {"slug":"slack","name":"Slack","config":{"url":"https://mcp.slack.com/mcp"},"limitation":"not yet"}]}
    , .{ .allocate = .alloc_always });
    const linear = (try fromCatalog(a, root, "Linear")).?;
    try std.testing.expectEqualStrings("https://mcp.linear.app/mcp", linear.cfg.get("url").?.string);
    const brave = (try fromCatalog(a, root, "brave")).?;
    try std.testing.expectEqualStrings("brave-search", brave.name);
    try std.testing.expectEqualStrings("BRAVE_API_KEY", brave.needs[0].env.?);
    try std.testing.expectEqualStrings("not yet", (try fromCatalog(a, root, "slack")).?.limitation.?);
    try std.testing.expect((try fromCatalog(a, root, "jira")) == null);
}

test "fromRegistry picks only a publisher that owns the name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("stripe", ownerOf("com.stripe/mcp"));
    try std.testing.expectEqualStrings("getsentry", ownerOf("io.github.getsentry/sentry-mcp"));
    const root = try std.json.parseFromSliceLeaky(Value, a,
        \\{"servers":[
        \\ {"server":{"name":"io.github.someone/stripe-mcp","packages":[{"registryType":"npm","identifier":"stripe-mcp-x","version":"1.0.0"}]}},
        \\ {"server":{"name":"com.stripe/mcp","title":"Stripe","remotes":[{"type":"streamable-http","url":"https://mcp.stripe.com"}]}},
        \\ {"server":{"name":"com.stripe/old","remotes":[{"type":"sse","url":"https://mcp.stripe.com/sse"}]},
        \\  "_meta":{"io.modelcontextprotocol.registry/official":{"status":"deprecated"}}}]}
    , .{ .allocate = .alloc_always });
    const got = try fromRegistry(a, root, "stripe");
    try std.testing.expectEqualStrings("https://mcp.stripe.com", got.found.cfg.get("url").?.string);
    try std.testing.expectEqualStrings("stripe", got.found.name);

    const pkg = try std.json.parseFromSliceLeaky(Value, a,
        \\{"servers":[{"server":{"name":"io.github.acme/acme","packages":[
        \\ {"registryType":"npm","identifier":"@acme/mcp","version":"2.1.0","transport":{"type":"stdio"},
        \\  "environmentVariables":[{"name":"ACME_TOKEN","isRequired":true,"description":"token"},{"name":"OPTIONAL"}]}]}}]}
    , .{ .allocate = .alloc_always });
    const acme = (try fromRegistry(a, pkg, "acme")).found;
    try std.testing.expectEqualStrings("npx", acme.cfg.get("command").?.string);
    try std.testing.expectEqualStrings("@acme/mcp@2.1.0", acme.cfg.get("args").?.array.items[1].string);
    try std.testing.expectEqual(@as(usize, 1), acme.needs.len);
    try std.testing.expectEqualStrings("ACME_TOKEN", acme.needs[0].env.?);

    const squat = try std.json.parseFromSliceLeaky(Value, a,
        \\{"servers":[{"server":{"name":"io.github.someone/linear-tools","packages":[{"registryType":"npm","identifier":"linear-tools"}]}}]}
    , .{ .allocate = .alloc_always });
    const listed = try fromRegistry(a, squat, "linear");
    try std.testing.expectEqualStrings("io.github.someone/linear-tools", listed.candidates[0]);
    try std.testing.expect((try fromRegistry(a, squat, "nothing-like-it")) == .not_found);
}
