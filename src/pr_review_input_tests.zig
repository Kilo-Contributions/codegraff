//! Budget regressions for pr_review_input (#1337, #1345), split out to keep
//! that file under the line cap.

const std = @import("std");
const inputs = @import("pr_review_input.zig");

test "#1345 an early large file cannot crowd out a later file's diff" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const gpa = std.testing.allocator;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    _ = try inputs.capture(gpa, io, a, cwd, &.{ "git", "init", "-q" });
    const large = try a.alloc(u8, 100 * 1024);
    @memset(large, 'a');
    for (large, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    large[0] = 'x';
    try temp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = large });
    try temp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = "one\ntwo\nthree\n" });
    const commit = &[_][]const u8{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qam", "c" };
    _ = try inputs.capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try inputs.capture(gpa, io, a, cwd, commit);
    const base = try inputs.capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    large[0] = 'y';
    try temp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = large });
    try temp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = "one\nTWO\nthree\n" });
    _ = try inputs.capture(gpa, io, a, cwd, commit);
    const head = try inputs.capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    // Size the claim so alpha's complete source would fill the budget exactly
    // to within a few bytes, leaving no room for beta's small diff.
    const alpha_diff = try inputs.raw(gpa, io, a, cwd, &.{ "git", "diff", "--no-ext-diff", "--no-renames", "--unified=3", base, head, "--", "alpha.txt" });
    const body = try a.alloc(u8, inputs.max_bytes - alpha_diff.len - large.len - 8);
    @memset(body, 'c');
    const input = try inputs.gather(gpa, io, a, cwd, base, head, body);
    try std.testing.expectEqual(@as(usize, 2), input.files.len);
    try std.testing.expect(input.files[0].after == null and input.files[0].after_omitted);
    try std.testing.expect(std.mem.indexOf(u8, input.files[0].change.?, "+yaaa") != null);
    try std.testing.expectEqualStrings("one\nTWO\nthree\n", input.files[1].after.?);
    try std.testing.expect(std.mem.indexOf(u8, input.files[1].change.?, "+TWO") != null);

    const slim = try inputs.diffsOnly(a, input);
    try std.testing.expectEqual(@as(usize, 2), slim.files.len);
    for (slim.files) |file| try std.testing.expect(file.after == null and file.after_omitted and file.change != null);
    try std.testing.expect(slim.support_omitted);
}

test "#1337 a large added fixture is reviewed as a marked excerpt, not refused" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const gpa = std.testing.allocator;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    const commit = &[_][]const u8{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "c" };
    _ = try inputs.capture(gpa, io, a, cwd, &.{ "git", "init", "-q" });
    try temp.dir.writeFile(io, .{ .sub_path = "lib.rs", .data = "fn a() {}\n" });
    _ = try inputs.capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try inputs.capture(gpa, io, a, cwd, commit);
    const base = try inputs.capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    const fixture = try a.alloc(u8, 90 * 1024);
    @memset(fixture, 'f');
    for (fixture, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    try temp.dir.writeFile(io, .{ .sub_path = "capture.txt", .data = fixture });
    try temp.dir.writeFile(io, .{ .sub_path = "lib.rs", .data = "fn a() { b() }\n" });
    _ = try inputs.capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try inputs.capture(gpa, io, a, cwd, commit);
    const head = try inputs.capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    const input = try inputs.gather(gpa, io, a, cwd, base, head, "claim");
    try std.testing.expectEqual(@as(usize, 2), input.files.len);
    try std.testing.expectEqualStrings("capture.txt", input.files[0].path);
    try std.testing.expect(input.files[0].change_truncated and input.files[0].after == null);
    try std.testing.expect(input.files[0].change.?.len <= inputs.max_file_diff + 64);
    try std.testing.expect(std.mem.indexOf(u8, input.files[0].change.?, "[diff truncated:") != null);
    try std.testing.expectEqualStrings("fn a() { b() }\n", input.files[1].after.?);
}
