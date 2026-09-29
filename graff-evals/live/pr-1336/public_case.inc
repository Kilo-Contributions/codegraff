
test "a check promoted to the background resolves when its job exits 0 (#1326)" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    const ev = @import("pr_evidence.zig");
    const target: ev.Target = .{ .cwd = cwd, .selector = "" };
    _ = try ev.capture(std.testing.allocator, io, a, target, &.{ "git", "init", "-q" });
    _ = try ev.capture(std.testing.allocator, io, a, target, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "base" });
    var root: @import("agent.zig").Agent = undefined;
    root.gpa = std.testing.allocator;
    root.arena = a;
    root.io = io;
    root.sub = false;
    root.agent_cwd = cwd;
    root.publication_checks = .{};
    const repository = try repositoryRoot(&root, cwd);
    const run = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"run\",\"command\":\"zig build test\"}", .{});
    const read = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"output\",\"id\":424242,\"wait_ms\":60000}", .{});

    // Output read: a nonzero exit keeps it unresolved, exit 0 resolves it.
    try record(&root, .{ .id = "run", .name = "shell", .input = run }, .{ .text = "[job 424242 started: zig build test]\nCommand exceeded the 120s foreground wait", .is_error = false, .pending = true });
    try std.testing.expect(root.publication_checks.unresolved(repository) != null);
    try record(&root, .{ .id = "read", .name = "shell", .input = read }, .{ .text = "[job 424242: exited with code 1]\nfailed", .is_error = true });
    try std.testing.expect(root.publication_checks.unresolved(repository) != null);
    try record(&root, .{ .id = "run2", .name = "shell", .input = run }, .{ .text = "[job 424243 started: zig build test]", .is_error = false, .pending = true });
    const reread = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"output\",\"id\":424243}", .{});
    try record(&root, .{ .id = "read2", .name = "shell", .input = reread }, .{ .text = "[job 424243: exited with code 0]\nAll 3 tests passed.", .is_error = false });
    try std.testing.expect(root.publication_checks.unresolved(repository) == null);
    const receipt = root.publication_checks.recent.items[root.publication_checks.recent.items.len - 1];
    try std.testing.expect(receipt.completed and !receipt.failed);
    try std.testing.expectEqualStrings("zig build test", receipt.command);

    // Never read: the publication gate consults the job's recorded exit.
    try record(&root, .{ .id = "run3", .name = "shell", .input = run }, .{ .text = "[job 424244 started: zig build test]", .is_error = false, .pending = true });
    try std.testing.expect(root.publication_checks.unresolved(repository) != null);
    const job_notify = @import("job_notify.zig");
    job_notify.queue(io, 424244, 0, false, "zig build test", false, "ok");
    try resolveFinishedJobs(&root);
    try std.testing.expect(root.publication_checks.unresolved(repository) == null);
    job_notify.dismiss(io, 424244);
}
