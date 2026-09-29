
test "one check in one directory is one entry whatever its spelling" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const repo = path[0..try temp.dir.realPath(io, &path)];
    const ev = @import("pr_evidence.zig");
    _ = try ev.capture(std.testing.allocator, io, a, .{ .cwd = repo, .selector = "" }, &.{ "git", "init", "-q" });
    try temp.dir.createDirPath(io, "app");
    const app = try std.fs.path.join(a, &.{ repo, "app" });
    var root: @import("agent.zig").Agent = undefined;
    root.gpa = std.testing.allocator;
    root.arena = a;
    root.io = io;
    root.sub = false;
    root.agent_cwd = repo;
    root.publication_checks = .{};
    const repository = try repositoryRoot(&root, repo);
    const failing = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"run\",\"command\":\"cd app && zig build test\"}", .{});
    try record(&root, .{ .id = "a", .name = "shell", .input = failing }, .{ .text = "FAIL", .is_error = true });
    try std.testing.expectEqualStrings("zig build test", root.publication_checks.unresolved(repository).?);
    // The same check, spelled without the cd and with extra spaces, from app/.
    root.agent_cwd = app;
    const passing = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"run\",\"command\":\"zig  build   test\"}", .{});
    try record(&root, .{ .id = "b", .name = "shell", .input = passing }, .{ .text = "All tests passed", .is_error = false });
    try std.testing.expect(root.publication_checks.unresolved(repository) == null);
}
