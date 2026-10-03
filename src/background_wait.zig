//! What a parked turn is waiting on (ADR 0247): the running shell jobs and
//! background agents whose exit wakes the session (ADR 0154), named for the
//! yield notice and for the standing block above `›`. Without a name the
//! yield read as graff stopping mid-task. A persistent server never exits to
//! wake anything, so it is named only when nothing finite is left, and never
//! with a promise to continue.

const std = @import("std");
const Io = std.Io;

const util = @import("util.zig");

pub const Waiting = struct {
    /// "zig build test", "zig build and 2 more", "agent 2". Empty when
    /// nothing is running. Job ids stay out: they are session handles the
    /// model reads off the tool result, noise on a line meant for people.
    text: []const u8 = "",
    /// Something finite is running: its exit resumes the session on its own.
    wakes: bool = false,
};

pub const Shell = struct { id: u64, cmd: []const u8, persistent: bool = false };

const cmd_clip: usize = 48;

/// The command as one short line: its first non-blank line, clipped.
fn shortCmd(cmd: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, cmd, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0) return util.utf8Prefix(line, cmd_clip);
    }
    return "command";
}

/// True when shortCmd dropped anything: the rest of a long line, or more lines.
fn clipped(cmd: []const u8) bool {
    return shortCmd(cmd).len < std.mem.trim(u8, cmd, " \t\r\n").len;
}

/// Pure: name these live jobs and agents. Finite work leads; a persistent
/// server is named only when it is all there is.
pub fn label(buf: []u8, shells: []const Shell, agents: []const u32) Waiting {
    var finite: usize = 0;
    var first: ?Shell = null;
    var server: ?Shell = null;
    for (shells) |s| {
        if (s.persistent) {
            if (server == null) server = s;
            continue;
        }
        if (first == null) first = s;
        finite += 1;
    }
    var w: Io.Writer = .fixed(buf);
    const total = finite + agents.len;
    if (total == 0) {
        const s = server orelse return .{};
        w.print("{s}{s}", .{ shortCmd(s.cmd), if (clipped(s.cmd)) "…" else "" }) catch return .{ .text = "a background server" };
        return .{ .text = w.buffered() };
    }
    if (first) |s| {
        w.print("{s}{s}", .{ shortCmd(s.cmd), if (clipped(s.cmd)) "…" else "" }) catch return .{ .text = "background work", .wakes = true };
    } else {
        w.print("agent {d}", .{agents[0]}) catch return .{ .text = "a background agent", .wakes = true };
    }
    if (total > 1) w.print(" and {d} more", .{total - 1}) catch {};
    return .{ .text = w.buffered(), .wakes = true };
}

/// The live registries, read under their own locks one at a time: shell jobs
/// that will post an exit notice (not the foreground wait, not a job a
/// finished session detached) and this session's unfinished agents.
pub fn describe(io: Io, buf: []u8) Waiting {
    var agent_ids: [8]u32 = undefined;
    var n_agents: usize = 0;
    {
        const agents = &@import("subagent.zig").g_agent_jobs;
        agents.mutex.lockUncancelable(io);
        defer agents.mutex.unlock(io);
        for (agents.list.items) |job| {
            if (job.done or job.owner == null) continue;
            if (n_agents < agent_ids.len) {
                agent_ids[n_agents] = job.id;
                n_agents += 1;
            }
        }
    }
    var shells: [8]Shell = undefined;
    var n_shells: usize = 0;
    const jobs = &@import("jobs.zig").g_jobs;
    jobs.mutex.lockUncancelable(io);
    defer jobs.mutex.unlock(io);
    for (jobs.list.items) |job| {
        if (job.done or job.quiet or job.detach) continue;
        if (n_shells < shells.len) {
            shells[n_shells] = .{ .id = job.id, .cmd = job.cmd, .persistent = job.persistent };
            n_shells += 1;
        }
    }
    // Formatted under the jobs lock: the command bytes belong to the job.
    return label(buf, shells[0..n_shells], agent_ids[0..n_agents]);
}

/// The line that ends a parked turn (ADR 0154), plain text: it is also the
/// turn's recorded result.
pub fn yieldNotice(a: std.mem.Allocator, w: Waiting) ![]const u8 {
    if (w.wakes) return std.fmt.allocPrint(a, "Still running: {s}. graff continues when it finishes; the prompt is free meanwhile.", .{w.text});
    if (w.text.len > 0) return std.fmt.allocPrint(a, "{s} keeps running in the background. graff is waiting for your next message.", .{w.text});
    return a.dupe(u8, "Background work is running; graff continues when it reports. The prompt is free meanwhile.");
}

/// The line printed when a wake resumes a parked session: what finished, from
/// the wake's first line, without the job's session handle.
/// "[job 12 exited 0: zig build test]" reads "zig build test exited 0".
pub fn resumeLine(buf: []u8, wake: []const u8) []const u8 {
    const text = std.mem.trim(u8, wake, " \t\r\n");
    const first = std.mem.trim(u8, std.mem.sliceTo(text, '\n'), " \t\r");
    if (std.mem.startsWith(u8, text, "[job ")) {
        // "[job ID STATUS: CMD]", where a multi-line command spans lines.
        var close: ?usize = std.mem.indexOf(u8, text, "]\n");
        if (close == null and std.mem.endsWith(u8, text, "]")) close = text.len - 1;
        if (close) |c| {
            const body = text["[job ".len..c];
            if (std.mem.indexOfScalar(u8, body, ' ')) |after_id| {
                const rest = body[after_id + 1 ..];
                if (std.mem.indexOf(u8, rest, ": ")) |colon| {
                    const cmd = rest[colon + 2 ..];
                    return std.fmt.bufPrint(buf, "{s}{s} {s}", .{ shortCmd(cmd), if (clipped(cmd)) "…" else "", rest[0..colon] }) catch util.utf8Prefix(first, 72);
                }
            }
        }
    }
    if (std.mem.startsWith(u8, first, "[agent ")) {
        if (std.mem.indexOfScalar(u8, first, ']')) |close| return first[1..close];
    }
    return util.utf8Prefix(first, 72);
}

test "ADR 0247: a resumed session names what finished, not its handle" {
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings("zig build test exited 0", resumeLine(&buf, "[job 4294978433 exited 0: zig build test]\nAll 2 tests passed."));
    try std.testing.expectEqualStrings("next dev killed", resumeLine(&buf, "[job 7 killed: next dev]"));
    try std.testing.expectEqualStrings("python3 - <<'PY'… stopped idle", resumeLine(&buf, "[job 8 stopped idle: python3 - <<'PY'\nprint(1)\nPY]"));
    try std.testing.expectEqualStrings("agent 2 completed", resumeLine(&buf, "[agent 2 completed] Read its report with agent_output (no wait)."));
    try std.testing.expectEqualStrings("a scheduled check is due", resumeLine(&buf, "a scheduled check is due\nmore"));
}

test "ADR 0247: a parked command is named by its command line" {
    var buf: [128]u8 = undefined;
    const w = label(&buf, &.{.{ .id = 3, .cmd = "terraform plan -out=tf.plan" }}, &.{});
    try std.testing.expectEqualStrings("terraform plan -out=tf.plan", w.text);
    try std.testing.expect(w.wakes);
}

test "ADR 0247: more work is counted, agents too, and finite work leads" {
    var buf: [128]u8 = undefined;
    const shells = [_]Shell{
        .{ .id = 4, .cmd = "next dev", .persistent = true },
        .{ .id = 5, .cmd = "zig build test" },
        .{ .id = 6, .cmd = "gh run watch 123" },
    };
    const w = label(&buf, &shells, &.{2});
    try std.testing.expectEqualStrings("zig build test and 2 more", w.text);
    try std.testing.expect(w.wakes);
    const only_agents = label(&buf, &.{}, &.{ 7, 8 });
    try std.testing.expectEqualStrings("agent 7 and 1 more", only_agents.text);
    try std.testing.expect(only_agents.wakes);
}

test "ADR 0247: a server alone is named but never promised to wake the session" {
    var buf: [128]u8 = undefined;
    const w = label(&buf, &.{.{ .id = 4, .cmd = "next dev --port 3777", .persistent = true }}, &.{});
    try std.testing.expectEqualStrings("next dev --port 3777", w.text);
    try std.testing.expect(!w.wakes);
    const notice = try yieldNotice(std.testing.allocator, w);
    defer std.testing.allocator.free(notice);
    try std.testing.expect(std.mem.indexOf(u8, notice, "continues") == null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "waiting for your next message") != null);
}

test "ADR 0247: long and multi-line commands shrink to one clipped line" {
    var buf: [128]u8 = undefined;
    const script = "python3 - <<'PY'\nimport json\nprint(1)\nPY";
    try std.testing.expectEqualStrings("python3 - <<'PY'…", label(&buf, &.{.{ .id = 9, .cmd = script }}, &.{}).text);
    const long = "bun run scripts/migrate-every-table-in-the-database.ts --all --verbose";
    const w = label(&buf, &.{.{ .id = 1, .cmd = long }}, &.{});
    try std.testing.expect(std.mem.endsWith(u8, w.text, "…"));
    try std.testing.expectEqual(@as(usize, 0), label(&buf, &.{}, &.{}).text.len);
}

test "ADR 0247: the yield notice says graff continues on its own" {
    const notice = try yieldNotice(std.testing.allocator, .{ .text = "zig build", .wakes = true });
    defer std.testing.allocator.free(notice);
    try std.testing.expectEqualStrings("Still running: zig build. graff continues when it finishes; the prompt is free meanwhile.", notice);
}
