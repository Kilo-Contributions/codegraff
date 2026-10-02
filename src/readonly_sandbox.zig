//! ADR 0232: a read-only child's foreground shell runs under macOS seatbelt.
//! Any command may run and read; nothing may write inside the project or
//! reach the network. That is what a read-only child of the codex route gets
//! from its sandbox. The allowlist alone refused python, awk and gzip, so an
//! informational child could not compute anything it was asked to report.
//! Elsewhere, and for a command sent to the background, the read-only gate
//! keeps its allowlist.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Part of every macOS install; a missing binary fails the spawn, it never
/// runs the command unsandboxed.
pub const exe = "/usr/bin/sandbox-exec";
pub const available = builtin.os.tag == .macos;

/// The gate's half: a foreground shell command is admitted because it will
/// run under the sandbox.
pub fn admits(input: std.json.Value) bool {
    return available and !@import("json_args.zig").flag(input, "run_in_background");
}

/// Everything allowed; then every write denied but temp, terminal and
/// descriptor paths; then every write under `root` denied again (the last
/// matching rule wins, so a project under /tmp stays read-only); no network.
pub fn profile(buf: []u8, root: []const u8) ?[]const u8 {
    var w: Io.Writer = .fixed(buf);
    w.writeAll("(version 1)(allow default)(deny file-write*)" ++
        "(allow file-write* (subpath \"/private/tmp\") (subpath \"/private/var/folders\") (literal \"/dev/null\") (regex #\"^/dev/tty\") (regex #\"^/dev/fd/\"))" ++
        "(deny file-write* (subpath \"") catch return null;
    for (root) |c| {
        if (c == '"' or c == '\\') w.writeByte('\\') catch return null;
        w.writeByte(c) catch return null;
    }
    w.writeAll("\"))(deny network*)") catch return null;
    return w.buffered();
}

/// Sized only where there is a sandbox: the caller keeps this on its stack.
const path_cap = if (available) std.fs.max_path_bytes else 1;

pub const Argv = struct {
    root: [path_cap]u8 = undefined,
    profile: [path_cap + 512]u8 = undefined,
    argv: [8][]const u8 = undefined,
};

/// `cmd` under the sandbox, rooted at the real path of `cwd` (null: the
/// process cwd). null when there is no sandbox here or the root does not
/// resolve; the caller then refuses anything the allowlist would not pass.
pub fn build(io: Io, cwd: ?[]const u8, cmd: []const u8, out: *Argv) ?[]const []const u8 {
    if (!available) return null;
    const n = Io.Dir.cwd().realPathFile(io, cwd orelse ".", &out.root) catch return null;
    const p = profile(&out.profile, out.root[0..n]) orelse return null;
    // git status would take index.lock, a write the sandbox refuses.
    out.argv = .{ exe, "-p", p, "/usr/bin/env", "GIT_OPTIONAL_LOCKS=0", "/bin/sh", "-c", cmd };
    return &out.argv;
}

/// The allowlist a read-only child keeps where there is no sandbox (the same
/// predicates plan mode and the read-only gate use).
pub fn allowlisted(cmd: []const u8) bool {
    const policy = @import("harness_policy.zig");
    const c = std.mem.trim(u8, cmd, " \t");
    return policy.readOnlyAllowed(c) or policy.readOnlyExternal(c);
}

pub const refusal = "this subagent is read-only (an informational task) and its shell sandbox is unavailable — run read-only commands from the allowlist (ls, cat, head, tail, wc, grep, rg, git status/diff/log/show), and report the change instead of making it";

test "read-only sandbox: the project is the last word on writes, and paths are quoted" {
    var buf: [512]u8 = undefined;
    const p = profile(&buf, "/private/tmp/a \"b\"").?;
    try std.testing.expect(std.mem.endsWith(u8, p, "(deny file-write* (subpath \"/private/tmp/a \\\"b\\\"\"))(deny network*)"));
    try std.testing.expect(std.mem.indexOf(u8, p, "(allow file-write* (subpath \"/private/tmp\")").? < std.mem.lastIndexOf(u8, p, "(deny file-write*").?);
    var small: [16]u8 = undefined;
    try std.testing.expect(profile(&small, "/x") == null);
}

test "read-only sandbox: python reads and computes, writes in the project fail" {
    if (!available) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = "a b ERROR E401\n" });
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(dir);
    var out: Argv = .{};
    const argv = build(io, dir, "python3 -c \"print(open('in.txt').read().split()[3])\" && (echo no > out.txt || echo denied)", &out) orelse return error.SkipZigTest;
    const jobs = @import("jobs.zig");
    const run = jobs.runCappedWithOptions(gpa, io, argv, 4096, 4096, 20_000, jobs.toolRunOptions(dir)) catch return error.SkipZigTest;
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    if (std.mem.indexOf(u8, run.stderr, "python3") != null and std.mem.indexOf(u8, run.stdout, "E401") == null) return error.SkipZigTest; // no python3 here
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "E401") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "denied") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out.txt", .{}));
}
