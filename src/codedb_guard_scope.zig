//! Which shell commands the codedb guard (#626, `tools.codedbGuard`) lets
//! through even though they name an indexed source file (ADR 0234).
//!
//! The guard moves source SEARCHES, and reads of files too big to take whole,
//! onto codedb. Two shapes are neither, and blocking them only cost the model
//! a round trip: an in-place edit (`sed -i`) writes the file and reads nothing
//! back, and a whole-file read of a small file returns no more than a
//! `read_file` would.

const std = @import("std");
const Io = std.Io;

/// A whole-file read of files up to this size passes: the size a tool result
/// keeps inline before it becomes a handle.
pub const small_read_bytes: u64 = @import("tool_handle.zig").default_threshold_bytes;

/// `sed` with an in-place flag (`-i`, `-i ''`, `-i.bak`, `-Ei`, `--in-place`)
/// in its first command segment.
pub fn inPlaceEdit(tool: []const u8, cmd: []const u8) bool {
    if (!std.mem.eql(u8, tool, "sed")) return false;
    const segment = cmd[0 .. std.mem.indexOfAny(u8, cmd, ";|&\n") orelse cmd.len];
    var it = std.mem.tokenizeAny(u8, segment, " \t");
    _ = it.next(); // sed itself
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "--in-place")) return true;
        if (tok.len < 2 or tok[0] != '-' or tok[1] == '-') continue;
        // A short-flag cluster: letters only up to an optional backup suffix.
        if (std.mem.indexOfScalar(u8, tok[1..], 'i')) |i| {
            if (std.mem.indexOfNone(u8, tok[1 .. 1 + i], "Ealnrsuz") == null) return true;
        }
    }
    return false;
}

fn plainReader(tool: []const u8) bool {
    for ([_][]const u8{ "cat", "head", "tail", "nl", "wc", "bat", "batcat" }) |reader|
        if (std.mem.eql(u8, reader, tool)) return true;
    return false;
}

/// `smallRead` in the directory the command runs in: the agent's own
/// worktree when it has one, else the process cwd.
pub fn smallReadIn(io: Io, agent_cwd: ?[]const u8, tool: []const u8, cmd: []const u8) bool {
    const path = agent_cwd orelse return smallRead(io, Io.Dir.cwd(), tool, cmd);
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer dir.close(io);
    return smallRead(io, dir, tool, cmd);
}

/// A plain reader (cat/head/tail/nl/wc/bat) with no pipe (`cat x | grep` is a
/// search) whose every named file is at most `small_read_bytes`. Paths
/// resolve against `cwd`, where the command runs.
pub fn smallRead(io: Io, cwd: Io.Dir, tool: []const u8, cmd: []const u8) bool {
    if (!plainReader(tool)) return false;
    if (std.mem.indexOfScalar(u8, cmd, '|') != null) return false;
    var it = std.mem.tokenizeAny(u8, cmd, " \t\n;&");
    var files: usize = 0;
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, "'\"`()");
        if (tok.len == 0 or tok[0] == '-') continue;
        const st = cwd.statFile(io, tok, .{}) catch continue; // a command word, a flag value, a missing file
        if (st.kind != .file) continue;
        if (st.size > small_read_bytes) return false;
        files += 1;
    }
    return files > 0;
}

test "inPlaceEdit: in-place sed edits, not reads or scripts" {
    try std.testing.expect(inPlaceEdit("sed", "sed -i '' 's/range(n - 1)/range(n)/' fib.py && python3 test_fib.py"));
    try std.testing.expect(inPlaceEdit("sed", "sed -i 's/a/b/' x.py; python3 x.py"));
    try std.testing.expect(inPlaceEdit("sed", "sed -i.bak -e 's/a/b/' x.py"));
    try std.testing.expect(inPlaceEdit("sed", "sed -Ei 's/a/b/g' x.py"));
    try std.testing.expect(inPlaceEdit("sed", "sed --in-place=.orig 's/a/b/' x.py"));
    try std.testing.expect(!inPlaceEdit("sed", "sed -n '1,20p' x.py"));
    try std.testing.expect(!inPlaceEdit("sed", "sed -n 's/i/x/p' x.py"));
    try std.testing.expect(!inPlaceEdit("sed", "sed -e 's/i/x/' x.py"));
    try std.testing.expect(!inPlaceEdit("sed", "sed -n 1p x.py; sed -i '' 's/a/b/' y.py")); // the edit is not the guarded command
    try std.testing.expect(!inPlaceEdit("grep", "grep -i foo x.py"));
}

test "smallRead: whole small files pass; big files, pipes and searches do not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "small.py", .data = "print(1)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.py", .data = "x = 2\n" });
    const big = try std.testing.allocator.alloc(u8, small_read_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try tmp.dir.writeFile(io, .{ .sub_path = "big.py", .data = big });

    try std.testing.expect(smallRead(io, tmp.dir, "cat", "cat small.py; cat other.py"));
    try std.testing.expect(smallRead(io, tmp.dir, "head", "head -n 40 small.py"));
    try std.testing.expect(!smallRead(io, tmp.dir, "cat", "cat small.py big.py"));
    try std.testing.expect(!smallRead(io, tmp.dir, "cat", "cat small.py | grep print"));
    try std.testing.expect(!smallRead(io, tmp.dir, "grep", "grep print small.py"));
    try std.testing.expect(!smallRead(io, tmp.dir, "cat", "cat missing.py"));
}
