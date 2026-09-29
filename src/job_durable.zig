//! The pump for a job whose output goes to files (ADR 0218, job_capture.zig).
//! Same contract as jobs.jobPump — drain output into the job buffer, keep the
//! #199 idle clock, honour kill and detach, publish through jobs.finish — but
//! it polls the files instead of reading pipes, and learns that the job
//! ended from waitpid (graff's own child) or from the exit receipt and the
//! leader's start identity (a job re-attached after a restart).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const jobs = @import("jobs.zig");
const Job = jobs.Job;
const g_jobs = &jobs.g_jobs;
const job_capture = @import("job_capture.zig");
const Capture = job_capture.Capture;
const job_idle = @import("job_idle.zig");
const job_registry = @import("job_registry.zig");
const proc_identity = @import("proc_identity.zig");

/// Poll ticks: a fresh job is checked often so a quick exit reports quickly;
/// a long one settles at the max. An adopted job costs a process probe per
/// tick, so it polls slower.
const tick_first_ms: i64 = 10;
const tick_max_ms: i64 = 100;
const tick_adopted_ms: i64 = 250;

/// Write the recovery record once the job runs (its pid is known now).
pub fn record(io: Io, job: *Job, capture: *Capture, session: []const u8) void {
    capture.start_id = switch (proc_identity.probe(io, job.group_pid)) {
        .id => |v| v,
        else => 0,
    };
    job_capture.writeMeta(io, capture, .{
        .id = job.id,
        .session = session,
        .cmd = job.cmd,
        .cwd = job.cwd orelse "",
        .pid = job.group_pid,
        .start_id = capture.start_id,
        .owner_pid = proc_identity.selfPid(),
        .owner_start_id = proc_identity.selfStartId(io),
        .started_ms = job.started_ms,
    });
}

pub fn pump(job: *Job, gpa: Allocator, io: Io) void {
    const capture = job.capture.?;
    const pid = job.group_pid;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(gpa);
    var code: ?u8 = null;
    var ended = false;
    var killed = false;
    var detached = false;
    var tick = if (capture.adopted) tick_adopted_ms else tick_first_ms;
    while (true) {
        // The end first, then the output: whatever the job wrote before it
        // exited is in the files by the time its exit is visible.
        ended = if (capture.adopted) adoptedEnded(io, capture, pid, &code) else ownEnded(pid, &code);
        const warn = drain(job, gpa, io, capture, &out, &err, !ended);
        g_jobs.mutex.lockUncancelable(io);
        killed = job.kill_requested;
        detached = job.detach;
        g_jobs.mutex.unlock(io);
        if (warn) |idle_ms| job_idle.warn(io, job.id, idle_ms, job.cmd);
        if (ended or killed or detached) break;
        io.sleep(.fromMilliseconds(tick), .awake) catch {};
        if (!capture.adopted) tick = @min(tick * 2, tick_max_ms);
    }
    if (!ended and killed and !detached) {
        stop(io, capture, pid);
        _ = drain(job, gpa, io, capture, &out, &err, false); // what it printed before the kill
    }
    // Reaped (or never ours): nothing may wait on or signal this child again.
    job.child.id = null;
    jobs.finish(job, io, if (ended) code else null, killed and !ended, detached and !ended, pid);
}

/// Read new output into the job buffer; with `idle`, also run the #199 idle
/// clock. Returns the idle time when the warning is due.
fn drain(job: *Job, gpa: Allocator, io: Io, capture: *Capture, out: *std.ArrayList(u8), err: *std.ArrayList(u8), idle: bool) ?u64 {
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    var skipped = job_capture.readNew(io, gpa, capture, .stdout, jobs.job_unread_cap, out);
    if (job_capture.readNew(io, gpa, capture, .stderr, jobs.job_unread_cap, err)) skipped = true;
    const now = jobs.nowMs(io);
    g_jobs.mutex.lockUncancelable(io);
    defer g_jobs.mutex.unlock(io);
    jobs.appendOutput(job, gpa, 0, out.items, now);
    jobs.appendOutput(job, gpa, 1, err.items, now);
    if (skipped) job.dropped = true;
    jobs.capUnread(job, gpa);
    return if (idle) jobs.idleTick(job, gpa, io, job.group_pid, now) else null;
}

/// graff's own child: reap it without blocking once it exits.
fn ownEnded(pid: i32, code: *?u8) bool {
    if (pid <= 0) return true; // no leader to wait on (never 0: that waits on the group)
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == 0) return false;
        if (rc == pid) {
            const st: u32 = @bitCast(status);
            code.* = if (std.posix.W.IFEXITED(st)) std.posix.W.EXITSTATUS(st) else null;
            return true;
        }
        if (std.posix.errno(rc) == .INTR) continue;
        code.* = null; // not ours to reap any more: ended, status unknown
        return true;
    }
}

/// A re-attached job: the receipt says it ended; a leader that is gone (or
/// whose pid now names another process) without one ended with no status.
fn adoptedEnded(io: Io, capture: *const Capture, pid: i32, code: *?u8) bool {
    const state = job_registry.stateOf(capture.start_id, proc_identity.probe(io, pid));
    code.* = job_capture.exitStatus(io, capture.dir);
    return code.* != null or state == .gone;
}

/// bash_kill, the idle stop, or session end. The whole group goes (#198);
/// a re-attached one only while its leader still carries the recorded start
/// identity (#413), so a recycled pid never gets an unrelated tree killed.
fn stop(io: Io, capture: *const Capture, pid: i32) void {
    if (pid <= 0) return;
    if (capture.adopted) {
        if (job_registry.stateOf(capture.start_id, proc_identity.probe(io, pid)) == .running)
            std.posix.kill(-pid, .KILL) catch {};
        return;
    }
    std.posix.kill(-pid, .KILL) catch {};
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) == -1 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
}

test "a background job with a session writes to files, reports through bash_output, and dies to bash_kill" {
    if (!job_capture.enabled) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    jobs.g_jobs = .{};
    @import("job_notify.zig").resetForTest(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = rbuf[0..try tmp.dir.realPath(io, &rbuf)];
    job_capture.test_root = root;
    defer job_capture.test_root = null;
    defer jobs.jobsReap(gpa, io);

    const done = try jobs.spawnJobOpts(gpa, io, "printf a; printf b >&2; exit 4", .{ .session = "s-live" });
    try std.testing.expect(done.capture != null);
    const out = try jobs.jobOutput(gpa, io, done.id, 5000);
    defer gpa.free(out.text);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "exited with code 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "ab") != null);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const meta = job_capture.readMeta(io, arena.allocator(), done.capture.?.dir) orelse return error.NoMeta;
    try std.testing.expectEqualStrings("s-live", meta.session);
    try std.testing.expectEqual(done.group_pid, meta.pid);
    try std.testing.expect(job_capture.reported(io, done.capture.?.dir));

    const slow = try jobs.spawnJobOpts(gpa, io, "sleep 30", .{ .session = "s-live" });
    const pid = slow.group_pid;
    const killed = try jobs.jobKill(gpa, io, slow.id);
    defer gpa.free(killed.text);
    try std.testing.expect(std.mem.indexOf(u8, killed.text, "killed") != null);
    try std.testing.expect(proc_identity.probe(io, pid) == .gone);

    // A server keeps its pipes; so does a job with no session to report to.
    const server = try jobs.spawnJobOpts(gpa, io, "exit 0", .{ .session = "s-live", .persistent = true });
    try std.testing.expect(server.capture == null);
    const plain = try jobs.spawnJobOpts(gpa, io, "exit 0", .{});
    try std.testing.expect(plain.capture == null);

    // Session end reaps them all and drops their capture directories.
    var nbuf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&nbuf, "{d}", .{done.id});
    jobs.jobsReap(gpa, io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, name, .{}));
}
