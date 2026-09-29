//! Job-pool administration split out of jobs.zig (600-line cap): the
//! ownership record a job leaves in ~/.codegraff/jobs (#199), /jobs keep and
//! restart, and the pinned-job handoff at session end.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const jobs = @import("jobs.zig");
const Job = jobs.Job;
const g_jobs = &jobs.g_jobs;
const nowMs = jobs.nowMs;
const job_registry = @import("job_registry.zig");
const browser_guard = @import("job_browser_guard.zig");
const proc_identity = @import("proc_identity.zig");

const posix_groups = builtin.os.tag != .windows and builtin.os.tag != .wasi;

/// The leader's start identity (#413), so a recycled pid is never mistaken
/// for the job. 0 where the platform has no source.
fn startIdOf(io: Io, pid: i32) u64 {
    return switch (proc_identity.probe(io, pid)) {
        .id => |v| v,
        else => 0,
    };
}

/// Caller holds the mutex (or owns the job outright).
pub fn recordOf(io: Io, job: *Job) job_registry.Record {
    const pid: i32 = job.group_pid; // an adopted job (ADR 0218) has no child id
    return .{
        .pid = pid,
        .start_id = startIdOf(io, pid),
        .owner_pid = proc_identity.selfPid(),
        .owner_start_id = proc_identity.selfStartId(io),
        .cmd = job.cmd,
        .cwd = job.cwd orelse "",
        .started_ms = job.started_ms,
        .pinned = job.pinned,
    };
}

/// /jobs keep|unkeep (#199): exempt from the idle stop, retained at session
/// end. Null for an unknown id, false for one that already finished.
pub fn setPinned(io: Io, id: u64, pinned: bool) ?bool {
    g_jobs.mutex.lockUncancelable(io);
    defer g_jobs.mutex.unlock(io);
    const job = g_jobs.find(id) orelse return null;
    if (job.done) return false;
    job.pinned = pinned;
    browser_guard.touch(job, nowMs(io));
    if (comptime posix_groups) job_registry.write(io, job_registry.home, recordOf(io, job));
    return true;
}

/// /jobs restart (#199): rerun a finished job's command in its cwd, as a new
/// job. The finished record stays listed until reaped.
pub fn restartJob(gpa: Allocator, io: Io, id: u64) !*Job {
    var cmd: []const u8 = "";
    var cwd: ?[]const u8 = null;
    {
        g_jobs.mutex.lockUncancelable(io);
        defer g_jobs.mutex.unlock(io);
        const job = g_jobs.find(id) orelse return error.NoSuchJob;
        if (!job.done) return error.StillRunning;
        cmd = job.cmd;
        cwd = job.cwd;
    }
    return jobs.spawnJobOpts(gpa, io, cmd, .{ .cwd = cwd });
}

/// Hand retained pipes to a detached drainer; failure never authorizes a kill.
pub fn retainAtExit(io: Io, job: *Job) bool {
    if (comptime !posix_groups) return false;
    const rec = recordOf(io, job);
    if (!job_registry.retain(io, job_registry.home, rec, job.child.stdout, job.child.stderr)) return false;
    std.debug.print("kept alive: job {d} (pid {d}) {s} — `graff servers` lists it; `graff servers stop {d}` ends it\n", .{ job.id, rec.pid, job.cmd, rec.pid });
    return true;
}
