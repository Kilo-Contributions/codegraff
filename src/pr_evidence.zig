//! Bounded GitHub CLI and git observations for artifact claims: the
//! repository and branch a mutation would touch. Missing data is unknown.
const std = @import("std");
const runner = @import("process_runner.zig");
const A = std.mem.Allocator;
pub const Target = struct { cwd: []const u8 = ".", repo: ?[]const u8 = null, selector: []const u8 };

pub fn capture(gpa: A, io: std.Io, a: A, target: Target, argv: []const []const u8) ![]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, argv);
    if (std.mem.eql(u8, argv[0], "gh")) if (target.repo) |repo| try args.appendSlice(a, &.{ "--repo", repo });
    const r = try runner.runCappedWithOptions(gpa, io, args.items, 256 * 1024, 2048, 15_000, .{ .cwd = .{ .path = target.cwd } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!runner.ranOk(r) or r.stdout_truncated or r.stderr_truncated) return error.EvidenceUnavailable;
    return a.dupe(u8, std.mem.trim(u8, r.stdout, " \r\n\t"));
}
