//! A PR command whose target could not be looked up (#1340, #1344).
//!
//! The claim gate resolves `gh pr <verb> N` to the PR's repository and head
//! branch before comparing it with foreign claims. When that lookup fails,
//! the target is unknown and a foreign claim still blocks conservatively,
//! except a numbered PR claim for a different number, which is provably
//! another artifact. The refusal then says what could not be resolved and
//! asks nobody for a handoff: the other session's claim was never shown to be
//! about this PR.

const std = @import("std");
const ledger = @import("artifact_claim_ledger.zig");
const Target = @import("artifact_claim_target.zig").Target;

/// Tests take the unresolved path; production reaches it when the lookup fails.
pub var g_force_for_test = false;

/// The literal PR number from the command, or an unknown target.
pub fn target(cmd: []const u8) Target {
    const t = @import("artifact_claim_target.zig").explicit(cmd, .pull_request) orelse return .{ .kind = .pull_request, .key = "" };
    return if (t.kind == .pull_request) t else .{ .kind = .pull_request, .key = "" };
}

/// A different numbered PR is another artifact whatever its branch.
pub fn provablyUnrelated(c: ledger.Claim, t: Target) bool {
    return c.kind == .pull_request and t.key.len > 0 and c.key.len > 0 and !std.mem.eql(u8, c.key, t.key);
}

pub fn refuseText(a: std.mem.Allocator, c: ledger.Claim, t: Target) []const u8 {
    return std.fmt.allocPrint(a, "artifact claim check: could not resolve which pull request this command targets{s}{s}{s} (the GitHub lookup failed), so another session's live {s} claim {s} blocks it conservatively. NOT performed; no handoff was requested because that claim was not shown to cover this PR. Retry the command, or run it from the PR's own worktree.", .{
        if (t.key.len > 0) " (#" else "",
        t.key,
        if (t.key.len > 0) ")" else "",
        @tagName(c.kind),
        if (c.key.len > 0) c.key else "(worktree)",
    }) catch "artifact claim check: the pull request target could not be resolved; NOT performed";
}

test "an unresolved explicit PR skips a different numbered claim only" {
    const t = target("gh pr edit 42 --body-file notes.md");
    try std.testing.expectEqualStrings("42", t.key);
    const other: ledger.Claim = .{ .kind = .pull_request, .key = "7", .owner = .{ .session = "peer", .pid = 1 } };
    const same: ledger.Claim = .{ .kind = .pull_request, .key = "42", .owner = .{ .session = "peer", .pid = 1 } };
    const branch: ledger.Claim = .{ .kind = .branch, .key = "feature", .owner = .{ .session = "peer", .pid = 1 } };
    try std.testing.expect(provablyUnrelated(other, t));
    try std.testing.expect(!provablyUnrelated(same, t));
    try std.testing.expect(!provablyUnrelated(branch, t));
    try std.testing.expect(!provablyUnrelated(other, target("gh pr edit --body-file notes.md")));
    const text = refuseText(std.testing.allocator, branch, t);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "(#42)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "no handoff was requested") != null);
}

test "#1344 the gate: another numbered PR claim does not block, a branch claim explains without a handoff" {
    const claims = @import("artifact_claim.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const io = std.testing.io;
    claims.resetForTest();
    defer claims.resetForTest();
    g_force_for_test = true;
    defer g_force_for_test = false;
    claims.setTestOwner(.{ .session = "s-owner" });
    _ = try claims.handleTool(ar, io, "claim", "pull_request", "7", "");
    claims.setTestOwner(.{ .session = "s-other" });
    claims.setTestOwnerLive(true);
    try std.testing.expect(claims.gateCommand(ar, io, "gh pr edit 42 --body-file notes.md", "") == null);
    const same = claims.gateCommand(ar, io, "gh pr edit 7 --body-file notes.md", "") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, same, "could not resolve") != null);
    claims.setTestOwner(.{ .session = "s-owner" });
    _ = try claims.handleTool(ar, io, "claim", "branch", "feature", "");
    claims.setTestOwner(.{ .session = "s-other" });
    const branch = claims.gateCommand(ar, io, "gh pr edit 42 --body-file notes.md", "") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, branch, "(#42)") != null);
    try std.testing.expect(std.mem.indexOf(u8, branch, "no handoff was requested") != null);
}
