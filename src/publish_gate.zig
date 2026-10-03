//! Bash-side artifact claim gate (#840): a mutation of a branch, PR or issue
//! another live session has claimed is refused before the command executes.
//! Presence ACK is a separate one-shot and does not clear the check. PR
//! readiness is not gated (ADR 0250).

const std = @import("std");
const builtin = @import("builtin");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const tools_mod = @import("tools.zig");
const ExecResult = tools_mod.ExecResult;
const artifact_claim = @import("artifact_claim.zig");

pub fn bash(self: *Agent, cmd: []const u8) !?ExecResult {
    const key = if (builtin.is_test) "" else mutationKey(self, cmd);
    if (artifact_claim.gateCommandIn(self.arena, self.io, cmd, key, self.agent_cwd orelse ".")) |blocked| return .{ .text = blocked, .is_error = true };
    return null;
}

fn mutationKey(self: *Agent, cmd: []const u8) []const u8 {
    if (!artifact_claim.isClaimedMutation(cmd)) return "";
    // Interpolation and globbing do not establish a comparable branch target.
    // Compound `;&|` still resolves via cwd or `git -C` (#1014).
    if (std.mem.indexOfAny(u8, cmd, "`$\"'\\*?{}") != null or
        std.mem.indexOf(u8, cmd, " -R") != null or std.mem.indexOf(u8, cmd, " --repo") != null) return "";
    const ev = @import("pr_evidence.zig");
    const c = @import("pr_command.zig").parse(self.arena, cmd) catch null;
    if (c) |command| {
        if (command.flag("--head", "-H")) |head| return head;
        if (!std.mem.eql(u8, command.verb, "create") and command.selector() != null) return "";
    }
    const git_c = @import("artifact_claim_command.zig").gitWorkDir(cmd);
    const cwd = git_c orelse if (c) |command| command.cwd orelse self.agent_cwd orelse "." else self.agent_cwd orelse ".";
    return ev.capture(self.gpa, self.io, self.arena, .{ .cwd = cwd, .selector = "" }, &.{ "git", "branch", "--show-current" }) catch "";
}

/// Recheck at the common bash execution boundary, including RLM host calls.
/// A permission checkpoint earlier in the turn is not a fresh handoff check.
pub fn beforeExec(ctx: tools_mod.ToolCtx, cmd: []const u8) !?tools_mod.ToolOutput {
    if (builtin.is_test) return null;
    if (!artifact_claim.isClaimedMutation(cmd)) return null;
    var scratch = std.heap.ArenaAllocator.init(ctx.gpa);
    defer scratch.deinit();
    var agent: Agent = .{ .gpa = ctx.gpa, .arena = scratch.allocator(), .io = ctx.io, .client = ctx.client, .provider = ctx.provider, .messages = undefined, .sub = ctx.from_sub, .label = "", .out = null, .agent_cwd = ctx.agent_cwd, .run_budget = ctx.run_budget, .depth = ctx.depth, .tracer = ctx.tracer, .loop_deadline_ms = ctx.loop_deadline_ms };
    if (try bash(&agent, cmd)) |denied| return .{ .text = try ctx.gpa.dupe(u8, denied.text), .is_error = true, .cancelled = denied.cancelled };
    return null;
}

test "#840 conflicting gh pr create never reaches execution after an acknowledged handoff" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    artifact_claim.resetForTest();
    defer artifact_claim.resetForTest();
    artifact_claim.setTestOwner(.{ .session = "s-owner", .pid = 1, .start_id = 1 });
    _ = try artifact_claim.handleTool(ar, std.testing.io, "claim", "publication", "", "");
    artifact_claim.setTestOwner(.{ .session = "s-other", .pid = 2, .start_id = 2 });
    artifact_claim.setTestOwnerLive(true);
    var agent: Agent = undefined;
    agent.arena = ar;
    agent.io = std.testing.io;
    const denied = (try bash(&agent, "gh pr create --title x --body '## Verification\\nzig build test'")).?;
    try std.testing.expect(denied.is_error);
    try std.testing.expect(std.mem.indexOf(u8, denied.text, "NOT performed") != null);
}

test "#879 read-only heredoc with publication text bypasses the claim gate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    artifact_claim.resetForTest();
    defer artifact_claim.resetForTest();
    artifact_claim.setTestOwner(.{ .session = "s-owner", .pid = 1, .start_id = 1 });
    _ = try artifact_claim.handleTool(ar, std.testing.io, "claim", "publication", "feat/x", "");
    artifact_claim.setTestOwner(.{ .session = "s-reader", .pid = 2, .start_id = 2 });
    artifact_claim.setTestOwnerLive(true);
    var agent: Agent = undefined;
    agent.arena = ar;
    agent.io = std.testing.io;
    const probe = "python3 - <<'PY'\nneedle = 'gh pr create --title x'\nprint(needle)\nPY";
    try std.testing.expect(try bash(&agent, probe) == null);
}

test "#840 warm dispatch observes late claims, lock contention and corrupt storage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const io = std.testing.io;
    const path = "zig-cache/claim-dispatch-840.json";
    const lock_path = path ++ ".lock";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
    artifact_claim.resetForTest();
    defer artifact_claim.resetForTest();
    artifact_claim.setPersistPath(path);
    artifact_claim.setTestOwner(.{ .session = "reader" });
    _ = try artifact_claim.handleTool(ar, io, "status", "publication", "feat/a", "");
    var agent: Agent = undefined;
    agent.arena = ar;
    agent.io = io;
    // A separate writer's persisted state, without resetting the warm reader.
    const foreign = "[{\"kind\":\"branch\",\"key\":\"feat/a\",\"session\":\"writer\",\"pid\":1,\"start_id\":0}]";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = foreign });
    try std.testing.expect((try bash(&agent, "gh pr create --draft --head feat/a")).?.is_error);
    try std.testing.expect(try bash(&agent, "gh pr list") == null);
    try std.testing.expect((try bash(&agent, "gh pr create --draft --head feat/a")).?.is_error);
    try std.testing.expect(try bash(&agent, "gh pr create --draft --head feat/b") == null);
    for ([_][]const u8{
        "gh issue list && gh pr create --draft --head feat/a",
        "gh issue list; gh pr create --draft --head feat/a",
        "gh issue list\ngh pr create --draft --head feat/a",
    }) |cmd| try std.testing.expect((try bash(&agent, cmd)).?.is_error);
    const held = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
    try std.testing.expect((try bash(&agent, "gh pr create --draft --head feat/a")).?.is_error);
    const blocked = try artifact_claim.handleTool(ar, io, "claim", "issue", "841", "");
    try std.testing.expect(blocked.is_error);
    held.close(io);
    const unchanged = try std.Io.Dir.cwd().readFileAlloc(io, path, ar, .limited(4096));
    try std.testing.expectEqualStrings(foreign, unchanged);
    var transferred: artifact_claim.Ledger = .{};
    try artifact_claim.loadJson(ar, &transferred, foreign);
    _ = try artifact_claim.handoff(&transferred, ar, .branch, "feat/a", .{ .session = "writer", .pid = 1 }, .{ .session = "reader" }, 0, true);
    try @import("credential_store.zig").replaceFile(io, std.Io.Dir.cwd(), path, try artifact_claim.persistJson(ar, &transferred), .default_file);
    try std.testing.expect(try bash(&agent, "gh pr create --draft --head feat/a") == null);
    artifact_claim.setTestOwner(.{ .session = "writer", .pid = 1 });
    try std.testing.expect((try bash(&agent, "gh pr create --draft --head feat/a")).?.is_error);
    _ = try artifact_claim.handleTool(ar, io, "claim", "issue", "840", "");
    artifact_claim.setTestOwner(.{ .session = "reader" });
    try std.testing.expect((try bash(&agent, "gh issue edit 840 --title x")).?.is_error);
    try std.testing.expect(try bash(&agent, "gh issue edit 841 --title x") == null);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "not json" });
    try std.testing.expect((try bash(&agent, "gh pr create --draft")).?.is_error);
    try std.testing.expect((try artifact_claim.handleTool(ar, io, "claim", "issue", "841", "")).is_error);
}

test "#840 publication branch keys are not compared with PR numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    artifact_claim.resetForTest();
    defer artifact_claim.resetForTest();
    artifact_claim.setTestOwner(.{ .session = "owner" });
    _ = try artifact_claim.handleTool(arena.allocator(), std.testing.io, "claim", "publication", "feat/a", "");
    artifact_claim.setTestOwner(.{ .session = "reader" });
    var agent: Agent = undefined;
    agent.arena = arena.allocator();
    agent.io = std.testing.io;
    try std.testing.expect(try bash(&agent, "gh pr edit 123 --title x") == null);
    try std.testing.expect(try bash(&agent, "gh pr create --draft --head feat/b") == null);
}
