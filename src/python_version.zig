//! ADR 0242: python3's version on this machine, for the shell tool's OS note.
//! Read from where `python3` on PATH resolves, never by running it: on a Mac
//! without the developer tools, /usr/bin/python3 opens an install dialog.
//! Detected once at startup, so the tool catalog stays byte-stable all session.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

var version_buf: [8]u8 = undefined;
/// "3.9", or empty when unknown. Written once by `detect`, before the first request.
pub var version: []const u8 = "";

/// The developer-tools interpreters macOS's /usr/bin/python3 launches.
const macos_dev_pythons = [_][]const u8{
    "/Library/Developer/CommandLineTools/usr/bin/python3",
    "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
};

/// Find the first `python3` on `path_env`, the one a shell command runs, and
/// read its version off the resolved path. `version` stays empty when no
/// python3 is on PATH or its path names no version (a pyenv shim, say).
pub fn detect(io: Io, path_env: ?[]const u8) void {
    version = "";
    if (builtin.os.tag == .windows) return;
    var dirs = std.mem.tokenizeScalar(u8, path_env orelse return, ':');
    while (dirs.next()) |dir| {
        var cand_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cand = std.fmt.bufPrint(&cand_buf, "{s}/python3", .{dir}) catch continue;
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = resolve(io, cand, &real_buf) orelse continue;
        if (fromPath(real)) |v| return remember(v);
        if (builtin.os.tag == .macos and std.mem.eql(u8, real, "/usr/bin/python3")) {
            for (macos_dev_pythons) |dev| {
                const r = resolve(io, dev, &real_buf) orelse continue;
                if (fromPath(r)) |v| return remember(v);
            }
        }
        return;
    }
}

fn resolve(io: Io, path: []const u8, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const n = Io.Dir.cwd().realPathFile(io, path, buf) catch return null;
    return buf[0..n];
}

fn remember(v: []const u8) void {
    @memcpy(version_buf[0..v.len], v);
    version = version_buf[0..v.len];
}

/// "3.N" from an interpreter's resolved path: `.../Versions/3.9/bin/python3.9`,
/// `/usr/bin/python3.11`, `.../python@3.12/...`. Null when it names none.
pub fn fromPath(path: []const u8) ?[]const u8 {
    for ([_][]const u8{ "python3.", "Versions/3.", "python@3." }) |pre| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, path, from, pre)) |at| : (from = at + 1) {
            const digits = at + pre.len;
            var end = digits;
            while (end < path.len and std.ascii.isDigit(path[end])) end += 1;
            if (end > digits and end - digits <= 3) return path[digits - 2 .. end];
        }
    }
    return null;
}

test "ADR 0242: fromPath reads the version a resolved interpreter path names" {
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3.9", "3.9" },
        .{ "/opt/homebrew/Cellar/python@3.12/3.12.4/Frameworks/Python.framework/Versions/3.12/bin/python3.12", "3.12" },
        .{ "/usr/bin/python3.11", "3.11" },
        .{ "/usr/bin/python3", null },
        .{ "/home/u/.pyenv/shims/python3", null },
    };
    for (cases) |c| {
        const got = fromPath(c[0]);
        if (c[1]) |want| try std.testing.expectEqualStrings(want, got orelse return error.NoVersion) else try std.testing.expect(got == null);
    }
}

test "ADR 0242: detect follows the first python3 on PATH and never a later one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/python3.10", .data = "" });
    try tmp.dir.symLink(io, "../real/python3.10", "b/python3", .{});
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var path_buf: [3 * std.fs.max_path_bytes]u8 = undefined;
    defer version = "";

    detect(io, try std.fmt.bufPrint(&path_buf, "{s}/a:{s}/b", .{ root, root }));
    try std.testing.expectEqualStrings("3.10", version);

    try tmp.dir.writeFile(io, .{ .sub_path = "a/python3", .data = "" }); // a shim: names no version
    detect(io, try std.fmt.bufPrint(&path_buf, "{s}/a:{s}/b", .{ root, root }));
    try std.testing.expectEqualStrings("", version);

    detect(io, null);
    try std.testing.expectEqualStrings("", version);
}
