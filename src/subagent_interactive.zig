//! Prompt-based interactive parents may yield after delegation and wake on
//! completion. Explicit positive waits instead honor agent_output's joined
//! completion contract, including cancellation.
const std = @import("std");
const tools = @import("tools.zig");
const subagent = @import("subagent.zig");

pub var enabled = std.atomic.Value(bool).init(false);
var requested = std.atomic.Value(bool).init(false);
pub var line_notice = false; // legacy line REPL provenance
pub var yielded = false; // root thread only
/// ADR 0247: the last yield's work resumes the session, so the standing
/// block above `›` names it and the yield itself need not print.
pub var yield_wakes = false;

pub fn stealIdleLine(io: std.Io, owner: []const u8, gpa: std.mem.Allocator, buf: anytype, idle: bool) !?[]u8 {
    if (!idle or !enabled.load(.acquire) or buf.items.len != 0) return null;
    var notice: [512]u8 = undefined;
    const text = takeWake(io, owner, &notice) orelse return null;
    try buf.appendSlice(gpa, text);
    line_notice = true;
    return buf.items;
}

pub fn configure(on: bool) void {
    enabled.store(on, .release);
    requested.store(false, .release);
    yielded = false;
    line_notice = false;
}

pub fn request(ctx: tools.ToolCtx) void {
    if (ctx.interactive_children and !ctx.from_sub) armYield();
}

/// The next model request will be replaced by the yield notice. Job completion
/// must stay queued for the idle auto-turn instead of landing in a turn that
/// is about to return without another model call (#1154).
/// Unattended sessions (ACP, one-shot) have no prompt to hand back. Yielding
/// there ends the turn before the model's next tool.
pub fn armYield() void {
    if (@import("main.zig").unattended) return;
    if (enabled.load(.acquire)) requested.store(true, .release);
}

pub fn yieldPending() bool {
    return enabled.load(.acquire) and requested.load(.acquire);
}

pub fn beforeRequest(root: anytype) !?[]const u8 {
    if (root.sub or !enabled.load(.acquire)) return null;
    yielded = requested.swap(false, .acq_rel);
    if (!yielded) return null;
    // ADR 0247: name what the session waits on and say it resumes on its own;
    // a bare "keep using the prompt" read as graff stopping mid-task.
    const bw = @import("background_wait.zig");
    var buf: [160]u8 = undefined;
    const waiting = bw.describe(root.io, &buf);
    yield_wakes = waiting.wakes;
    return try bw.yieldNotice(root.arena, waiting);
}

/// Consume only complete, previously unread jobs owned by this session. Full
/// reports remain in agent_output. A short buffer never consumes a partial id.
pub fn takeWake(io: std.Io, owner: []const u8, buf: []u8) ?[]const u8 {
    const registry = &subagent.g_agent_jobs;
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    var used: usize = 0;
    for (registry.list.items) |job| {
        if (!job.done or job.notified or job.owner == null) continue;
        if (!std.mem.eql(u8, job.owner.?, owner)) continue;
        const line = std.fmt.bufPrint(buf[used..], "{s}[agent {d} {s}] Read its report with agent_output (no wait). Reconcile it with the user's current task; do not restart paused or superseded work.", .{ if (used == 0) "" else "\n", job.id, if (job.is_error) "failed" else "completed" }) catch break;
        used += line.len;
        job.notified = true;
    }
    return if (used == 0) null else buf[0..used];
}

pub fn deliver(root: anytype) void {
    if (root.sub or !enabled.load(.acquire)) return;
    var buf: [512]u8 = undefined;
    const text = takeWake(root.io, root.session_name, &buf) orelse return;
    @import("session_wake.zig").inject(root, text);
}

/// Automatic session-title adoption renames the save file, not its children.
pub fn rename(io: std.Io, old: []const u8, new: []const u8) void {
    const registry = &subagent.g_agent_jobs;
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    for (registry.list.items) |job| {
        const owner = job.owner orelse continue;
        if (!std.mem.eql(u8, owner, old)) continue;
        const storage = job.owned orelse continue;
        job.owner = storage.arena.allocator().dupe(u8, new) catch continue;
    }
}

pub fn output(ctx: tools.ToolCtx, id: u32, wait_ms: u64) !tools.ToolOutput {
    // A positive wait is an explicit completion wait (ADR 0010), including
    // ACP/TUI roots. Only a zero-wait snapshot should park the interactive
    // parent and arrange a later wake; ignoring wait_ms spends model turns
    // polling a still-running child.
    if (!ctx.interactive_children or ctx.from_sub or wait_ms > 0) return subagent.agentOutput(ctx.gpa, ctx.io, id, wait_ms);
    const result = try subagent.agentOutput(ctx.gpa, ctx.io, id, 0);
    const registry = &subagent.g_agent_jobs;
    registry.mutex.lockUncancelable(ctx.io);
    defer registry.mutex.unlock(ctx.io);
    if (registry.find(id)) |job| if (!job.done) request(ctx);
    return result;
}

/// agent_output with ids: one call returns every listed agent's report,
/// waiting for all of them when wait_ms>0, where a call per id cost the
/// parent a model round trip each (ADR 0232). The agents run concurrently,
/// so the wait is the slowest one's. An error only when every agent failed:
/// each report already says which one did.
pub fn outputMany(ctx: tools.ToolCtx, ids: []const std.json.Value, wait_ms: u64) !tools.ToolOutput {
    if (ids.len == 0) return invalidIds(ctx.gpa);
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer out.deinit();
    var failed: usize = 0;
    for (ids, 0..) |value, i| {
        const id: u32 = switch (value) {
            .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else return invalidIds(ctx.gpa),
            else => return invalidIds(ctx.gpa),
        };
        const one = try output(ctx, id, wait_ms);
        defer ctx.gpa.free(one.text);
        if (one.is_error) failed += 1;
        if (i > 0) try out.writer.writeAll("\n\n");
        try out.writer.writeAll(one.text);
    }
    return .{ .text = try out.toOwnedSlice(), .is_error = failed == ids.len };
}

fn invalidIds(gpa: std.mem.Allocator) !tools.ToolOutput {
    return .{ .text = try gpa.dupe(u8, "agent_output: ids must be a non-empty list of agent ids"), .is_error = true };
}

test "beforeRequest yields so parked shell jobs free the prompt" {
    configure(true);
    defer configure(false);
    requested.store(true, .release);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const Fake = struct { sub: bool = false, arena: std.mem.Allocator, io: std.Io = std.testing.io };
    const text = (try beforeRequest(Fake{ .arena = arena_state.allocator() })) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, text, "graff continues") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "prompt is free") != null);
}
