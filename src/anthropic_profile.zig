//! Anthropic Console sign-in: graff uses the credential Anthropic's own CLI
//! (`ant auth login`) writes, exactly as Anthropic's SDKs do, so a Console
//! account and its workspace's API credits run claude-* models without an API
//! key. graff never runs Anthropic's OAuth client itself: `ant auth login`
//! signs in, and `ant auth print-credentials --access-token` refreshes.
//!
//! Layout (Anthropic SDK `config` package): the directory is
//! `ANTHROPIC_CONFIG_DIR`, else `%APPDATA%\Anthropic` on Windows, else
//! `$XDG_CONFIG_HOME/anthropic`, else `~/.config/anthropic`. The profile is
//! `ANTHROPIC_PROFILE`, else the one-line `active_config`, else `default`.
//! `configs/<p>.json` holds `authentication.type` (only `user_oauth` is read
//! here), `base_url` and `workspace_id`; `credentials/<p>.json` (or the
//! profile's `authentication.credentials_path`) holds `access_token` and
//! `expires_at` in Unix seconds.
//!
//! Precedence follows the SDK's: `ANTHROPIC_API_KEY` wins and profiles are
//! not read; a profile named by `ANTHROPIC_PROFILE` outranks a key stored with
//! `graff key`; the active profile fills in only when nothing else did.
//! A claude.ai subscription login is not a credential graff uses.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// Where the profile in use lives. Remembered at startup for the per-request
/// refresh, which has no environment of its own.
pub const Located = struct {
    dir: []const u8,
    profile: []const u8,
    /// Named by `ANTHROPIC_PROFILE` (outranks a stored key).
    named: bool,
};

pub const Profile = struct {
    token: []const u8,
    /// Unix seconds; null when the credential carries none.
    expires_at: ?i64 = null,
    workspace_id: ?[]const u8 = null,
    email: ?[]const u8 = null,
    workspace_name: ?[]const u8 = null,
};

/// Refresh this close to expiry; `ant` refreshes at the same threshold.
const refresh_margin_s: i64 = 120;
/// After a failed `ant` refresh, don't spawn it again on every request.
const retry_after_ms: i64 = 30_000;

var remembered: ?Located = null;
/// Anthropic's CLI; tests point it at a stand-in.
pub var ant_bin: []const u8 = "ant";
var last_failed_ms: i64 = 0;

pub fn locate(arena: Allocator, environ_map: anytype, home: []const u8) ?Located {
    const dir: []const u8 = blk: {
        if (environ_map.get("ANTHROPIC_CONFIG_DIR")) |d| break :blk d;
        if (builtin.os.tag == .windows) {
            const appdata = environ_map.get("APPDATA") orelse return null;
            break :blk std.fs.path.join(arena, &.{ appdata, "Anthropic" }) catch return null;
        }
        if (environ_map.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) break :blk std.fs.path.join(arena, &.{ x, "anthropic" }) catch return null;
        if (home.len == 0) return null;
        break :blk std.fs.path.join(arena, &.{ home, ".config", "anthropic" }) catch return null;
    };
    if (dir.len == 0) return null;
    if (environ_map.get("ANTHROPIC_PROFILE")) |p| if (p.len > 0) return .{ .dir = dir, .profile = p, .named = true };
    return .{ .dir = dir, .profile = "", .named = false };
}

/// `active_config`, else `default`, for an unnamed location.
fn profileName(io: Io, arena: Allocator, loc: Located) []const u8 {
    if (loc.profile.len > 0) return loc.profile;
    const path = std.fs.path.join(arena, &.{ loc.dir, "active_config" }) catch return "default";
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return "default";
    const name = std.mem.trim(u8, text, " \t\r\n");
    return if (name.len == 0) "default" else name;
}

fn readJson(io: Io, arena: Allocator, path: []const u8) ?std.json.ObjectMap {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return null;
    return if (v == .object) v.object else null;
}

fn str(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const v = obj.get(field) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

/// The profile's current credential, from disk only (no network, no `ant`).
/// Null unless it is a `user_oauth` profile for the default API host.
pub fn read(io: Io, arena: Allocator, loc: Located) ?Profile {
    const name = profileName(io, arena, loc);
    const cfg_path = std.fs.path.join(arena, &.{ loc.dir, "configs", std.fmt.allocPrint(arena, "{s}.json", .{name}) catch return null }) catch return null;
    const cfg = readJson(io, arena, cfg_path) orelse return null;
    const auth = cfg.get("authentication") orelse return null;
    if (auth != .object) return null;
    if (!std.mem.eql(u8, str(auth.object, "type") orelse "", "user_oauth")) return null;
    // A profile minted against another API host must not send its token to
    // the default one, nor the default host's traffic to it.
    if (str(cfg, "base_url")) |base| if (!std.mem.eql(u8, std.mem.trimEnd(u8, base, "/"), "https://api.anthropic.com")) return null;
    const creds_path = str(auth.object, "credentials_path") orelse
        (std.fs.path.join(arena, &.{ loc.dir, "credentials", std.fmt.allocPrint(arena, "{s}.json", .{name}) catch return null }) catch return null);
    const creds = readJson(io, arena, creds_path) orelse return null;
    const token = str(creds, "access_token") orelse return null;
    return .{
        .token = token,
        .expires_at = if (creds.get("expires_at")) |v| (if (v == .integer) v.integer else null) else null,
        .workspace_id = str(cfg, "workspace_id") orelse str(creds, "workspace_id"),
        .email = str(creds, "account_email"),
        .workspace_name = str(creds, "workspace_name"),
    };
}

/// Startup: the profile's token for the key table, and remember where it
/// lives for the per-request refresh. `named_only` reads only a profile named
/// by `ANTHROPIC_PROFILE` (the pass before stored keys).
pub fn load(io: Io, arena: Allocator, environ_map: anytype, home: []const u8, named_only: bool) ?[]const u8 {
    if (environ_map.get("ANTHROPIC_API_KEY") != null) return null; // the SDK's rule: a key shadows every profile
    const loc = locate(arena, environ_map, home) orelse return null;
    if (named_only and !loc.named) return null;
    const p = read(io, arena, loc) orelse return null;
    remember(loc, p);
    return std.heap.page_allocator.dupe(u8, p.token) catch null;
}

fn remember(loc: Located, p: Profile) void {
    const a = std.heap.page_allocator;
    _ = p;
    // The token is already bound to the workspace chosen at sign-in, so no
    // `anthropic-workspace-id` header is needed alongside it.
    remembered = .{ .dir = a.dupe(u8, loc.dir) catch return, .profile = a.dupe(u8, loc.profile) catch return, .named = loc.named };
}

/// Before a request (and, forced, after an auth error): the current token.
/// Reads the file; only near expiry (or forced) asks `ant` to refresh.
pub fn fresh(io: Io, gpa: Allocator, arena: Allocator, force: bool) ?[]const u8 {
    const loc = remembered orelse return null;
    const p = read(io, arena, loc) orelse return null;
    const now_ms = @import("util.zig").unixMs(io);
    const near = if (p.expires_at) |exp| exp * 1000 - now_ms <= refresh_margin_s * 1000 else false;
    if (!force and !near) return p.token;
    if (now_ms - last_failed_ms < retry_after_ms) return p.token;
    return refreshViaAnt(io, gpa, arena, profileName(io, arena, loc)) orelse {
        last_failed_ms = now_ms;
        return p.token;
    };
}

fn refreshViaAnt(io: Io, gpa: Allocator, arena: Allocator, profile: []const u8) ?[]const u8 {
    _ = gpa;
    const pr = @import("process_runner.zig");
    const run = pr.runCappedWithOptions(arena, io, &.{ ant_bin, "auth", "print-credentials", "--access-token", "--profile", profile }, 8192, 8192, 20_000, .{}) catch return null;
    if (!pr.ranOk(run)) return null;
    const token = std.mem.trim(u8, run.stdout, " \t\r\n");
    if (!std.mem.startsWith(u8, token, "sk-ant-")) return null;
    return token;
}

/// Console OAuth tokens go in `Authorization: Bearer`; API keys keep `x-api-key`.
pub fn bearerToken(provider_id: []const u8, key: []const u8) bool {
    return std.mem.eql(u8, provider_id, "anthropic") and std.mem.startsWith(u8, key, "sk-ant-oat");
}

/// `graff login anthropic`: Anthropic's CLI signs in (browser, Console
/// account, workspace); graff then reads what it wrote.
pub fn login(io: Io, arena: Allocator, environ_map: anytype, home: []const u8) !void {
    const style = &@import("ansi.zig").style;
    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &buf);
    const out = &w.interface;
    var child = std.process.spawn(io, .{ .argv = &.{ ant_bin, "auth", "login" }, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit }) catch |err| switch (err) {
        error.FileNotFound => {
            try out.writeAll(
                \\graff signs in to an Anthropic Console account through Anthropic's CLI, `ant`, which isn't installed.
                \\Install it, then run `graff login anthropic` again:
                \\  macOS:   brew install anthropics/tap/ant
                \\  Linux:   release binaries at https://github.com/anthropics/anthropic-cli/releases
                \\  Go:      go install github.com/anthropics/anthropic-cli/cmd/ant@latest
                \\Or use an API key instead: export ANTHROPIC_API_KEY=sk-ant-…
                \\
            );
            try out.flush();
            std.process.exit(1);
        },
        else => return err,
    };
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) std.process.fatal("ant auth login did not finish; nothing changed", .{});
    const loc = locate(arena, environ_map, home) orelse std.process.fatal("signed in, but no Anthropic config directory was found", .{});
    const p = read(io, arena, loc) orelse std.process.fatal("signed in, but the profile has no Console credential graff can use", .{});
    try out.print("{s}✓{s} graff will use your Anthropic Console sign-in for claude-* models", .{ style.green, style.reset });
    if (p.email) |e| try out.print(" — {s}", .{e});
    if (p.workspace_name) |ws| try out.print(", workspace {s}", .{ws});
    try out.writeAll(".\n  Requests are billed to that workspace's API credits.");
    if (environ_map.get("ANTHROPIC_API_KEY") != null) try out.writeAll("\n  ANTHROPIC_API_KEY is set and takes precedence; unset it to use this sign-in.");
    try out.writeAll("\n");
    try out.flush();
}

const testing = std.testing;

const Env = struct {
    map: []const [2][]const u8,
    pub fn get(self: Env, key: []const u8) ?[]const u8 {
        for (self.map) |kv| if (std.mem.eql(u8, kv[0], key)) return kv[1];
        return null;
    }
};

fn writeFile(io: Io, dir: Io.Dir, sub: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = sub, .data = data });
}

test "Console profile: read like the SDK; API key and other hosts shadow it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    try writeFile(io, tmp.dir, "active_config", "work\n");
    try writeFile(io, tmp.dir, "configs/work.json",
        \\{"version":"1.0","authentication":{"type":"user_oauth","client_id":"c"},"workspace_id":"wrkspc_1"}
    );
    try writeFile(io, tmp.dir, "credentials/work.json",
        \\{"version":"1.0","type":"oauth_token","access_token":"sk-ant-oat01-abc","expires_at":4102444800,"account_email":"dev@example.com","workspace_name":"Eng"}
    );
    try writeFile(io, tmp.dir, "configs/fed.json",
        \\{"authentication":{"type":"oidc_federation","federation_rule_id":"fdrl_1"}}
    );
    try writeFile(io, tmp.dir, "configs/staging.json",
        \\{"authentication":{"type":"user_oauth"},"base_url":"https://staging.example.com"}
    );
    try writeFile(io, tmp.dir, "credentials/staging.json",
        \\{"access_token":"sk-ant-oat01-stg"}
    );

    const active = Env{ .map = &.{.{ "ANTHROPIC_CONFIG_DIR", dir }} };
    const p = read(io, a, locate(a, active, "").?).?;
    try testing.expectEqualStrings("sk-ant-oat01-abc", p.token);
    try testing.expectEqual(@as(?i64, 4102444800), p.expires_at);
    try testing.expectEqualStrings("wrkspc_1", p.workspace_id.?);
    try testing.expectEqualStrings("Eng", p.workspace_name.?);
    try testing.expectEqualStrings("sk-ant-oat01-abc", load(io, a, active, "", false).?);
    // Only a named profile is read before stored keys.
    try testing.expect(load(io, a, active, "", true) == null);
    // ANTHROPIC_API_KEY shadows every profile, as in the SDK.
    try testing.expect(load(io, a, Env{ .map = &.{ .{ "ANTHROPIC_CONFIG_DIR", dir }, .{ "ANTHROPIC_API_KEY", "sk-ant-api03-x" } } }, "", false) == null);
    // Federation profiles and profiles for another API host are not used.
    try testing.expect(load(io, a, Env{ .map = &.{ .{ "ANTHROPIC_CONFIG_DIR", dir }, .{ "ANTHROPIC_PROFILE", "fed" } } }, "", true) == null);
    try testing.expect(load(io, a, Env{ .map = &.{ .{ "ANTHROPIC_CONFIG_DIR", dir }, .{ "ANTHROPIC_PROFILE", "staging" } } }, "", true) == null);
    // A named profile is read in the first pass.
    try testing.expectEqualStrings("sk-ant-oat01-abc", load(io, a, Env{ .map = &.{ .{ "ANTHROPIC_CONFIG_DIR", dir }, .{ "ANTHROPIC_PROFILE", "work" } } }, "", true).?);
    // A fresh token is returned from disk without asking `ant`.
    try testing.expectEqualStrings("sk-ant-oat01-abc", fresh(io, testing.allocator, a, false).?);
}

test "default directory follows the SDK: XDG, then ~/.config/anthropic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testing.expectEqualStrings("/x/anthropic", locate(a, Env{ .map = &.{.{ "XDG_CONFIG_HOME", "/x" }} }, "/home/u").?.dir);
    try testing.expectEqualStrings("/home/u/.config/anthropic", locate(a, Env{ .map = &.{} }, "/home/u").?.dir);
    try testing.expect(locate(a, Env{ .map = &.{} }, "") == null);
    try testing.expect(bearerToken("anthropic", "sk-ant-oat01-x"));
    try testing.expect(!bearerToken("anthropic", "sk-ant-api03-x"));
    try testing.expect(!bearerToken("minimax", "sk-ant-oat01-x"));
}

test "an expiring Console token is refreshed through ant, and sent as a bearer token" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // /bin/sh stand-in
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try writeFile(io, tmp.dir, "configs/default.json",
        \\{"authentication":{"type":"user_oauth","client_id":"c"}}
    );
    try writeFile(io, tmp.dir, "credentials/default.json",
        \\{"access_token":"sk-ant-oat01-old","expires_at":1}
    );
    try writeFile(io, tmp.dir, "ant", "#!/bin/sh\necho sk-ant-oat01-new\n");
    const script = try std.fs.path.join(a, &.{ dir, "ant" });
    try Io.Dir.cwd().setFilePermissions(io, script, .fromMode(0o755), .{});
    const saved = ant_bin;
    defer ant_bin = saved;
    ant_bin = script;
    last_failed_ms = 0;

    const env = Env{ .map = &.{.{ "ANTHROPIC_CONFIG_DIR", dir }} };
    try testing.expectEqualStrings("sk-ant-oat01-old", load(io, a, env, "", false).?);
    try testing.expectEqualStrings("sk-ant-oat01-new", fresh(io, testing.allocator, a, false).?);

    // The provider built from it authenticates with Bearer, not x-api-key.
    const provider_mod = @import("provider.zig");
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    try testing.expect(keys.set("anthropic", "sk-ant-oat01-new", .login));
    const p = keys.build(provider_mod.specFor("anthropic").?, "sk-ant-oat01-new", "claude-opus-5-5");
    try testing.expectEqual(provider_mod.Provider.Auth.bearer, p.auth);
    const api_key = keys.build(provider_mod.specFor("anthropic").?, "sk-ant-api03-k", "claude-opus-5-5");
    try testing.expectEqual(provider_mod.Provider.Auth.x_api_key, api_key.auth);
    // The model list (router_catalog) authenticates the same way.
    var hb: [4]std.http.Header = undefined;
    const hs = @import("router_catalog.zig").catalogHeaders(a, provider_mod.specFor("anthropic").?, "sk-ant-oat01-new", .login, &hb).?;
    try testing.expectEqualStrings("Authorization", hs[1].name);
    try testing.expectEqualStrings("Bearer sk-ant-oat01-new", hs[1].value);
}
