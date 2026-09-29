//! `/goal` is the one autonomous run (goal_pacing.autonomousFromLine).
//! These pin the seam mainloop depends on: which lines start a run, which stay
//! commands, where the duration goes, what the /goal command line becomes
//! once a duration has been stripped out of it, and how a continuation turn
//! stays in its run.
//!
//! Kept out of goal_pacing.zig (line cap) and reached through the `test { _ =
//! ... }` hook in main.zig - without that line these silently never run.

const std = @import("std");
const goal_pacing = @import("goal_pacing.zig");
const repl_glue = @import("repl_glue.zig");

/// mainloop's exact call shape for a typed line: the objective parse decides
/// command-vs-run, then autonomousFromLine turns a run into one descriptor.
fn parse(arena: std.mem.Allocator, line: []const u8) !?goal_pacing.Autonomous {
    return goal_pacing.autonomousFromLine(arena, line, repl_glue.goalPromptFromLine(line), false);
}

test "/goal is the one autonomous run; /loop no longer starts one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    const g = (try parse(ar, "/goal ship phase 2")).?;
    try std.testing.expectEqualStrings("ship phase 2", g.prompt);
    try std.testing.expect(g.deadline_ms_delta == null);
    try std.testing.expectEqualStrings("/goal ship phase 2", g.goal_line.?); // the command runs first

    // /loop was removed (ADR 0216): its line is a retired command, not a run.
    try std.testing.expect((try parse(ar, "/loop ship phase 2")) == null);
    try std.testing.expect((try parse(ar, "/loop 45s ship it")) == null);
}

test "a duration prefix never lands in the objective" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    const g = (try parse(ar, "/goal 30m fix the flaky test")).?;
    try std.testing.expectEqual(@as(?i64, 30 * std.time.ms_per_min), g.deadline_ms_delta);
    try std.testing.expectEqualStrings("fix the flaky test", g.prompt);
    // The rebuilt command is what /goal records: "30m" is the run's budget, not
    // part of what the user is trying to achieve.
    try std.testing.expectEqualStrings("/goal fix the flaky test", g.goal_line.?);
    try std.testing.expectEqualStrings("fix the flaky test", repl_glue.goalPromptFromLine(g.goal_line.?).?);
}

test "lifecycle words and bare invocations stay commands, not runs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    for ([_][]const u8{ "/goal status", "/goal pause", "/goal RESUME", "/goal clear", "/goal ", "/goal" }) |line|
        try std.testing.expect((try parse(ar, line)) == null);
    // An objective that merely STARTS with a lifecycle word is still a run.
    const c = (try parse(ar, "/goal clear the flaky tests")).?;
    try std.testing.expectEqualStrings("clear the flaky tests", c.prompt);
    // Ordinary prompts and other commands are not autonomous runs either.
    for ([_][]const u8{ "just answer this", "/model", "/loop" }) |line|
        try std.testing.expect((try parse(ar, line)) == null);
}

test "a continuation turn stays in its run: no objective and no new clock" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    // What mainloop synthesizes for continuation turns: the steering note, then
    // the pacing line. It must stay one run with no NEW deadline (the clock was
    // armed by the original line and is not re-armed on continuations).
    const line = "[continuing autonomously: keep working the checklist]\n[pace: continuation 2 of 25, 1m elapsed.]";
    const a = (try goal_pacing.autonomousFromLine(ar, line, null, true)).?;
    try std.testing.expect(a.deadline_ms_delta == null);
    try std.testing.expect(a.goal_line == null);
    try std.testing.expectEqualStrings(line, a.prompt);
    // A wake that happens to open like a duration is still not a budget.
    const wake = (try goal_pacing.autonomousFromLine(ar, "5m build finished\n\n[continuing autonomously: next step]", null, true)).?;
    try std.testing.expect(wake.deadline_ms_delta == null);
}
