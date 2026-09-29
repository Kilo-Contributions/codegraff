//! One line-REPL /loop run (#226): its iteration credits, the queued
//! continuation, the checklist gate and the wall clock. Moved out of
//! mainloop.zig (600-line cap) when #1278 added the hold.
//!
//! #1278: a loop turn that only started or waited on background work makes no
//! tool calls, so the controller read it as `idle` and ended the run. The
//! work's completion wake then ran as an ordinary turn, outside the loop's
//! credits and steering. Now, while the root still owns a running shell job or
//! background subagent that will report, the run holds instead: the next idle
//! wake continues it as a loop turn. A typed line ends the hold like a steer.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const goal_flow = @import("goal_flow.zig");
const goal_pacing = @import("goal_pacing.zig");
const repl_glue = @import("repl_glue.zig");
const util = @import("util.zig");
const style = &@import("ansi.zig").style;

/// Hard per-run iteration bound (the never-completing-model guard).
pub const iter_cap: u32 = 25;

pub const LoopRun = struct {
    iters_left: u32 = 0, // continuation turns still authorized this run
    armed: bool = false, // a continuation turn is queued for the next read
    holding: bool = false, // #1278: waiting for the root's background work to report
    list: goal_flow.LoopListGate = .{}, // diff-gate for the checklist copy (#318)
    clock: goal_pacing.LoopClock = .{}, // `/loop 30m <prompt>` deadline + pacing

    /// A user steer or typed line, or the run's end: nothing continues.
    pub fn cancel(self: *LoopRun, root: *Agent) void {
        self.iters_left = 0;
        self.armed = false;
        self.holding = false;
        self.list.reset();
        self.clock.clear(root); // and its deadline stops reaching subagents
    }

    /// The queued continuation turn's line, consumed here so an interrupted
    /// or errored turn does not resume the run. `wake` prefixes it when the
    /// continuation comes out of a hold.
    pub fn continuation(self: *LoopRun, arena: Allocator, root: *Agent, now_ms: i64, wake: []const u8) ![]const u8 {
        self.armed = false;
        // Gated: these prompts persist in root.messages, autosave, and are
        // compaction input, so the current epoch's list is pasted only when
        // it changed or a history rewrite destroyed the pasted copies (#318).
        const note = try self.list.note(arena, root);
        const pace = try goal_pacing.pacingNote(arena, now_ms, self.clock, iter_cap - self.iters_left, iter_cap);
        if (wake.len == 0) return std.fmt.allocPrint(arena, "/loop {s}\n{s}", .{ note, pace });
        return std.fmt.allocPrint(arena, "/loop {s}\n\n{s}\n{s}", .{ wake, note, pace });
    }

    /// A line read while holding. An idle wake (the work reporting) continues
    /// the run when a credit and the clock allow; anything typed ends it.
    /// Returns the continuation line, or null to handle `line` as read.
    pub fn afterRead(self: *LoopRun, arena: Allocator, root: *Agent, now_ms: i64, line: []const u8, from_wake: bool) !?[]const u8 {
        if (!self.holding) return null;
        self.holding = false;
        const expired = if (root.loop_deadline_ms) |deadline| now_ms >= deadline else false;
        if (!from_wake or expired or self.iters_left == 0) {
            self.cancel(root);
            return null;
        }
        self.iters_left -= 1;
        return try self.continuation(arena, root, now_ms, line);
    }

    /// After a clean /loop turn the CONTROLLER decides whether another runs,
    /// not the model merely stopping (goal_flow.loopTurnDecision).
    pub fn afterTurn(self: *LoopRun, root: *Agent, io: Io, out: *Io.Writer, is_continuation: bool) !void {
        if (!is_continuation) {
            self.iters_left = iter_cap; // fresh run: arm the bound
            self.list.reset(); // and a clean gate: its first continuation carries the list in full
        }
        switch (goal_flow.loopTurnDecision(root, self.iters_left, util.unixMs(io))) {
            .continue_turn => {
                self.iters_left -= 1; // one credit for the queued continuation
                self.armed = true;
            },
            .stop => |outcome| {
                if (holds(outcome, self.iters_left, liveBackgroundWork(io))) {
                    self.holding = true;
                    try out.print("{s}↻ run waiting — background work is still running; the run continues when it reports (type to take over){s}\n", .{ style.accent, style.reset });
                    try out.flush();
                    if (root.tracer) |t| t.note("loop", "holding");
                    return;
                }
                self.cancel(root);
                // Only work_done reaches `accepted`, so the loop drove the
                // goal to done; a --goal standing objective outlives it (#318).
                if (outcome == .accepted) _ = goal_flow.acceptLoopOutcome(root);
                const tone = if (outcome == .accepted) style.green else style.yellow; // success must not look like the four failures
                try out.print("{s}↩ run stopped — {s}{s}\n", .{ tone, if (@import("subagent_interactive.zig").yielded) "waiting for delegated work; prompt available" else repl_glue.outcomeText(outcome, iter_cap), style.reset });
                try out.flush();
                if (root.tracer) |t| t.note("loop", @tagName(outcome)); // every /goal transition is traced; the run's end was not
            },
        }
    }
};

/// Only a turn that stopped for want of work holds, and only while there is
/// work that will wake the run and a credit to spend when it does.
pub fn holds(outcome: repl_glue.ContinuationOutcome, iters_left: u32, live_work: bool) bool {
    return outcome == .idle and iters_left > 0 and live_work;
}

/// A running shell job that will post a completion notice, or a background
/// subagent owned by this session (its completion is an idle wake).
fn liveBackgroundWork(io: Io) bool {
    const jobs = &@import("jobs.zig").g_jobs;
    {
        jobs.mutex.lockUncancelable(io);
        defer jobs.mutex.unlock(io);
        for (jobs.list.items) |job| if (!job.done and !job.quiet and !job.detach) return true;
    }
    const agents = &@import("subagent.zig").g_agent_jobs;
    agents.mutex.lockUncancelable(io);
    defer agents.mutex.unlock(io);
    for (agents.list.items) |job| if (!job.done and job.owner != null) return true;
    return false;
}

test "#1278: only an idle stop with live work and a credit left holds" {
    try std.testing.expect(holds(.idle, 5, true));
    try std.testing.expect(!holds(.idle, 5, false)); // nothing will wake it
    try std.testing.expect(!holds(.idle, 0, true)); // no credit to continue with
    for ([_]repl_glue.ContinuationOutcome{ .accepted, .exhausted, .expired, .blocked, .cancelled }) |outcome|
        try std.testing.expect(!holds(outcome, 5, true));
}

test "#1278: a wake during a hold continues the run; a typed line or a spent run ends it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: Agent = undefined;
    root.loop_deadline_ms = null;
    root.history_rewrites = 0;
    root.todos = .empty;
    root.goal = null;
    const wake = "[job 7 exited 0: zig build test]";

    var run: LoopRun = .{ .iters_left = 3, .holding = true };
    const line = (try run.afterRead(arena, &root, 1_000, wake, true)).?;
    try std.testing.expect(std.mem.startsWith(u8, line, "/loop " ++ wake ++ "\n\n[continuing autonomously (/loop)"));
    try std.testing.expect(!run.holding and run.iters_left == 2);

    var typed: LoopRun = .{ .iters_left = 3, .holding = true };
    try std.testing.expect(try typed.afterRead(arena, &root, 1_000, "do something else", false) == null);
    try std.testing.expect(!typed.holding and typed.iters_left == 0);

    root.loop_deadline_ms = 500;
    var late: LoopRun = .{ .iters_left = 3, .holding = true };
    try std.testing.expect(try late.afterRead(arena, &root, 1_000, wake, true) == null); // out of time
    try std.testing.expect(late.iters_left == 0);

    var idle: LoopRun = .{};
    try std.testing.expect(try idle.afterRead(arena, &root, 1_000, wake, true) == null); // no hold: an ordinary wake
}
