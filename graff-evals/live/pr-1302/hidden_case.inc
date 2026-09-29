
test "mixed documentation changes leave room for committed test roots" {
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
    try temp.dir.createDirPath(io, "src");
    const docs = try a.alloc(u8, 60 * 1024);
    const source = try a.alloc(u8, 50 * 1024);
    @memset(docs, 'a');
    @memset(source, 'a');
    for (docs, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    for (source, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    docs[0] = 'x';
    source[0] = 'x';
    docs[docs.len - 1] = '\n';
    source[source.len - 1] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "README.md", .data = docs });
    try temp.dir.writeFile(io, .{ .sub_path = "dispatch.zig", .data = source });
    try temp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = source });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "base" });
    const base = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    docs[0] = 'y';
    source[0] = 'y';
    try temp.dir.writeFile(io, .{ .sub_path = "README.md", .data = docs });
    try temp.dir.writeFile(io, .{ .sub_path = "dispatch.zig", .data = source });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "head" });
    const head = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    const input = try gather(gpa, io, a, cwd, base, head, "claim");
    try std.testing.expectEqual(@as(usize, 3), input.files.len);
    try std.testing.expectEqualStrings("README.md", input.files[0].path);
    try std.testing.expect(input.files[0].after == null and input.files[0].after_omitted);
    try std.testing.expect(std.mem.indexOf(u8, input.files[0].change.?, "+yaaa") != null);
    try std.testing.expectEqual(@as(u8, 'y'), input.files[1].after.?[0]);
    try std.testing.expect(!input.files[1].after_omitted);
    try std.testing.expectEqualStrings("src/main.zig", input.files[2].path);
    try std.testing.expectEqual(@as(u8, 'x'), input.files[2].after.?[0]);
    try std.testing.expect(!input.support_omitted);
}
