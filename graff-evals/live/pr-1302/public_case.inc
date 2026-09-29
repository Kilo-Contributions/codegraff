
test "claim review uses committed context when changed head source exceeds the budget" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const gpa = std.testing.allocator;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    _ = try capture(gpa, io, a, cwd, &.{ "git", "init", "-q" });
    const source = try a.alloc(u8, 75 * 1024);
    @memset(source, 'a');
    for (source, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    source[0] = 'x';
    source[source.len - 1] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = source });
    try temp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = source });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "base" });
    const base = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    source[0] = 'y';
    try temp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = source });
    try temp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = source });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "head" });
    const head = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    source[0] = 'u';
    try temp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = source });
    const input = try gather(gpa, io, a, cwd, base, head, "claim");
    try std.testing.expectEqual(@as(usize, 2), input.files.len);
    try std.testing.expectEqual(@as(u8, 'y'), input.files[0].after.?[0]);
    try std.testing.expect(!input.files[0].after_omitted);
    try std.testing.expect(input.files[1].after == null);
    try std.testing.expect(input.files[1].after_omitted);
    try std.testing.expect(std.mem.indexOf(u8, input.files[1].change.?, "+yaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, input.files[1].change.?, "+uaaa") == null);

    const large = try a.alloc(u8, max_bytes + 1024);
    @memset(large, 'a');
    for (large, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    large[0] = 'x';
    large[large.len - 1] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = large });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "large-base" });
    const large_base = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    large[0] = 'y';
    try temp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = large });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "large-head" });
    const large_head = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    const single = try gather(gpa, io, a, cwd, large_base, large_head, "claim");
    try std.testing.expectEqual(@as(usize, 1), single.files.len);
    try std.testing.expect(single.files[0].after == null and single.files[0].after_omitted);
    try std.testing.expect(std.mem.indexOf(u8, single.files[0].change.?, "+yaaa") != null);
}
