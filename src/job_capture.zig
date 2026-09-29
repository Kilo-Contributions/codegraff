//! Durable background jobs (crash survival, ADR 0218). A finite job started in
//! the background writes its stdout and stderr straight to files under
//! `.graff/job-output/<id>/` instead of pipes into graff, and its shell leaves
//! an exit receipt beside them. graff dying mid-task (a crash, a SIGKILL, a
//! closed terminal) then neither kills the job on its next write nor loses
//! what it printed: resuming the session re-attaches a job that is still
//! running and reports one that finished while graff was down
//! (job_recover.zig).
//!
//! POSIX only. Servers and foreground commands keep pipes: a server never
//! finishes, and a foreground call's `cmd &` idioms depend on pipe EOF.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const enabled = builtin.os.tag != .windows and builtin.os.tag != .wasi;
pub const dir_rel = ".graff/job-output";

/// A reader that has caught up past this empties the file: the job appends,
/// so it carries on from 0 and a chatty job cannot fill the disk while graff
/// watches it.
pub const trunc_at: u64 = 8 * 1024 * 1024;

/// The job's own shell writes its exit status to `$2` on the way out. An
/// EXIT trap in that one shell, not a parent wrapper, so `exec cmd` still
/// makes `cmd` the process-group leader. `set --` leaves the command with no
/// positional parameters, as under `sh -c cmd`. A command that execs or sets
/// its own EXIT trap leaves no receipt; graff's own waitpid still sees it.
pub const wrapper = "__graff_cmd=$1 __graff_exit=$2; set --; trap 'printf \"%s\\n\" \"$?\" >\"$__graff_exit\"' EXIT; eval \"$__graff_cmd\"";

/// What survives the process that started the job.
pub const Meta = struct {
    id: u64,
    session: []const u8,
    cmd: []const u8,
    cwd: []const u8 = "",
    pid: i32 = 0,
    start_id: u64 = 0,
    owner_pid: i32 = 0,
    owner_start_id: u64 = 0,
    started_ms: i64 = 0,
};

pub const Stream = enum(u1) { stdout, stderr };

/// A job's capture directory and how far each output file has been read.
pub const Capture = struct {
    dir: []u8, // absolute, gpa-owned
    offs: [2]u64 = .{ 0, 0 },
    readers: [2]?Io.File = .{ null, null },
    /// Re-attached after a restart: not graff's child, so it is watched
    /// through its receipt and its leader's start identity, never waitpid.
    adopted: bool = false,
    start_id: u64 = 0,

    pub fn path(self: *const Capture, buf: []u8, name: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.dir, name }) catch "";
    }
};

/// Test override for the capture root, so unit tests never touch the
/// workspace's own `.graff`.
pub var test_root: ?[]const u8 = null;

/// `<cwd>/.graff/job-output`, absolute: a job running in a worktree agent's
/// cwd, or past a later workspace switch, still writes its receipt here.
pub fn rootPath(io: Io, buf: []u8) ?[]const u8 {
    if (builtin.is_test) if (test_root) |r| return std.fmt.bufPrint(buf, "{s}", .{r}) catch null;
    var cwd: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(io, &cwd) catch return null;
    return std.fmt.bufPrint(buf, "{s}/" ++ dir_rel, .{cwd[0..n]}) catch null;
}

/// A capture made ready for spawn: the child's argv and its two output files.
pub const Setup = struct {
    capture: *Capture,
    argv: [6][]const u8,
    exit_path: []u8, // gpa-owned; argv borrows it until spawn returns
    out: Io.File,
    err: Io.File,

    /// Spawn copied argv and dup'ed the files: the child holds its own.
    pub fn spawned(self: *Setup, gpa: Allocator, io: Io) void {
        self.out.close(io);
        self.err.close(io);
        gpa.free(self.exit_path);
    }

    /// Spawn failed: nothing runs, so nothing is kept.
    pub fn abandon(self: *Setup, gpa: Allocator, io: Io) void {
        self.spawned(gpa, io);
        release(gpa, io, self.capture, true);
    }
};

/// Create `<root>/<id>/` with empty output files and the argv that runs `cmd`
/// with an exit receipt. Null when it cannot: durability is best-effort, and
/// the caller keeps the job on pipes.
pub fn prepare(io: Io, gpa: Allocator, id: u64, cmd: []const u8) ?Setup {
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = rootPath(io, &rbuf) orelse return null;
    if (!builtin.is_test) @import("graff_dir.zig").ensure(io, Io.Dir.cwd()); // #1273: out of git
    return create(io, gpa, root, id, cmd) catch null;
}

pub fn create(io: Io, gpa: Allocator, root: []const u8, id: u64, cmd: []const u8) !Setup {
    const dir = try std.fmt.allocPrint(gpa, "{s}/{d}", .{ root, id });
    errdefer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    errdefer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const capture = try gpa.create(Capture);
    errdefer gpa.destroy(capture);
    capture.* = .{ .dir = dir };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = try openAppend(capture.path(&buf, "stdout"));
    errdefer out.close(io);
    const err = try openAppend(capture.path(&buf, "stderr"));
    errdefer err.close(io);
    const exit_path = try gpa.dupe(u8, capture.path(&buf, "exit"));
    return .{
        .capture = capture,
        .argv = .{ "/bin/sh", "-c", wrapper, "/bin/sh", cmd, exit_path },
        .exit_path = exit_path,
        .out = out,
        .err = err,
    };
}

/// O_APPEND, so a reader may empty the file under a writer (see trunc_at).
fn openAppend(path: []const u8) !Io.File {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .APPEND = true, .CLOEXEC = true }, 0o600);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Best-effort: a missing record costs recovery, never the job.
pub fn writeMeta(io: Io, capture: *const Capture, meta: Meta) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var jbuf: [16 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&jbuf);
    var s: std.json.Stringify = .{ .writer = &w };
    s.write(meta) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = capture.path(&buf, "meta.json"), .data = w.buffered() }) catch {};
}

pub fn readMeta(io: Io, arena: Allocator, dir: []const u8) ?Meta {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/meta.json", .{dir}) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 * 1024)) catch return null;
    return std.json.parseFromSliceLeaky(Meta, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// The recorded exit status, or null while the job runs (or when it ended
/// without its shell reaching the EXIT trap).
pub fn exitStatus(io: Io, dir: []const u8) ?u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/exit", .{dir}) catch return null;
    var data: [16]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, p, &data) catch return null;
    return std.fmt.parseInt(u8, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

/// The exit reached the model: a restart must not report it again.
pub fn markReported(io: Io, capture: *const Capture) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = capture.path(&buf, "reported"), .data = "" }) catch {};
}

pub fn reported(io: Io, dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/reported", .{dir}) catch return false;
    Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}

/// New bytes of one output file since the last read, appended to `out`. Keeps
/// the newest `keep` bytes of a larger burst and returns true when it skipped
/// older ones.
pub fn readNew(io: Io, gpa: Allocator, capture: *Capture, which: Stream, keep: usize, out: *std.ArrayList(u8)) bool {
    const i = @intFromEnum(which);
    const f = capture.readers[i] orelse blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const opened = Io.Dir.cwd().openFile(io, capture.path(&buf, @tagName(which)), .{ .mode = .read_write }) catch return false;
        capture.readers[i] = opened;
        break :blk opened;
    };
    const off = &capture.offs[i];
    const len = f.length(io) catch return false;
    if (len < off.*) off.* = 0; // emptied elsewhere: start over
    var skipped = false;
    if (len - off.* > keep) {
        off.* = len - keep;
        skipped = true;
    }
    var chunk: [64 * 1024]u8 = undefined;
    var bufs = [_][]u8{&chunk};
    while (off.* < len) {
        const n = f.readPositional(io, &bufs, off.*) catch break;
        if (n == 0) break;
        const take = @min(n, len - off.*);
        out.appendSlice(gpa, chunk[0..take]) catch break;
        off.* += take;
    }
    if (off.* >= trunc_at and off.* == (f.length(io) catch 0)) {
        f.setLength(io, 0) catch return skipped;
        off.* = 0;
    }
    return skipped;
}

/// Close the readers and free the capture. The directory goes too unless the
/// job still writes to it (kept past session end).
pub fn release(gpa: Allocator, io: Io, capture: *Capture, remove: bool) void {
    for (capture.readers) |r| if (r) |f| f.close(io);
    if (remove) Io.Dir.cwd().deleteTree(io, capture.dir) catch {};
    gpa.free(capture.dir);
    gpa.destroy(capture);
}

test "the receipt records the command's own exit status, and output lands in the files" {
    if (!enabled) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = rbuf[0..try tmp.dir.realPath(io, &rbuf)];
    var setup = try create(io, gpa, root, 42, "printf out; printf err >&2; [ $# -eq 0 ] || exit 9; exit 7");
    var child = try std.process.spawn(io, .{ .argv = &setup.argv, .stdin = .ignore, .stdout = .{ .file = setup.out }, .stderr = .{ .file = setup.err } });
    const capture = setup.capture;
    setup.spawned(gpa, io);
    const term = try child.wait(io);
    try std.testing.expectEqual(@as(u8, 7), term.exited);
    try std.testing.expectEqual(@as(?u8, 7), exitStatus(io, capture.dir));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expect(!readNew(io, gpa, capture, .stdout, 1024, &out));
    try std.testing.expect(!readNew(io, gpa, capture, .stderr, 1024, &out));
    try std.testing.expectEqualStrings("outerr", out.items);
    _ = readNew(io, gpa, capture, .stdout, 1024, &out); // nothing new: offsets advanced
    try std.testing.expectEqualStrings("outerr", out.items);

    writeMeta(io, capture, .{ .id = 42, .session = "s-1", .cmd = "exit 7", .pid = 99 });
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const meta = readMeta(io, arena.allocator(), capture.dir).?;
    try std.testing.expectEqual(@as(u64, 42), meta.id);
    try std.testing.expectEqualStrings("s-1", meta.session);
    try std.testing.expect(!reported(io, capture.dir));
    markReported(io, capture);
    try std.testing.expect(reported(io, capture.dir));
    release(gpa, io, capture, true);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "42", .{}));
}

test "exec keeps the command as the group leader; a burst past keep skips its oldest bytes" {
    if (!enabled) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = rbuf[0..try tmp.dir.realPath(io, &rbuf)];
    // `exec` replaces the job's shell, so no receipt: the leader is the command.
    var setup = try create(io, gpa, root, 43, "printf 0123456789; exec /bin/sh -c 'echo $$ >&2'");
    var child = try std.process.spawn(io, .{ .argv = &setup.argv, .stdin = .ignore, .stdout = .{ .file = setup.out }, .stderr = .{ .file = setup.err }, .pgid = 0 });
    const pid = child.id.?;
    const capture = setup.capture;
    defer release(gpa, io, capture, true);
    setup.spawned(gpa, io);
    _ = try child.wait(io);
    try std.testing.expectEqual(@as(?u8, null), exitStatus(io, capture.dir));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expect(readNew(io, gpa, capture, .stdout, 4, &out));
    try std.testing.expectEqualStrings("6789", out.items);
    out.clearRetainingCapacity();
    _ = readNew(io, gpa, capture, .stderr, 64, &out);
    var pbuf: [16]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&pbuf, "{d}\n", .{pid}), out.items);
}
