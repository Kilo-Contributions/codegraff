//! mcp_shapes tests moved off mcp_shapes.zig for the 600-line cap.

const std = @import("std");
const shapes = @import("mcp_shapes.zig");

test "annotate states the slim rule on every load result, stored shapes or not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    shapes.reset(gpa, io);
    defer shapes.reset(gpa, io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const annotated = try shapes.annotate(gpa, arena_state.allocator(), io, dir, "1 tool schema(s) below");
    try std.testing.expect(std.mem.startsWith(u8, annotated, "1 tool schema(s) below"));
    try std.testing.expect(std.mem.indexOf(u8, annotated, "latest_author") != null);
    try std.testing.expect(std.mem.indexOf(u8, annotated, "return_shapes") == null); // nothing stored yet
    try std.testing.expect(std.mem.indexOf(u8, @import("mcp_schema_gate.zig").tool_desc, "come back slimmed") == null); // never the prefix
}

test "slim drops description/body; comments fold to n and latest_author" {
    const gpa = std.testing.allocator;
    try std.testing.expect(shapes.slim(gpa, "[{\"id\":1}]") == null);
    const pad: [400]u8 = @splat('x');
    const pad_s: []const u8 = &pad;
    const issues = try std.fmt.allocPrint(gpa, "[{{\"id\":\"ISS-1\",\"identifier\":\"ENG-101\",\"title\":\"Login\",\"description\":\"{s}\",\"body\":\"KEEP-OUT\"}},{{\"id\":\"ISS-2\",\"identifier\":\"ENG-102\",\"title\":\"Tax\",\"description\":\"{s}\"}}]", .{ pad_s, pad_s });
    defer gpa.free(issues);
    const cut = shapes.slim(gpa, issues) orelse return error.ExpectedSlim;
    defer gpa.free(cut);
    try std.testing.expect(std.mem.indexOf(u8, cut, "ISS-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "ENG-101") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "Login") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "description") == null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "KEEP-OUT") == null);
    try std.testing.expect(std.mem.indexOf(u8, cut, pad_s) == null);

    const comments = try std.fmt.allocPrint(gpa, "[{{\"body\":\"old {s}\",\"author\":{{\"name\":\"ada\"}},\"createdAt\":\"2026-08-11T01:00:00Z\"}},{{\"body\":\"new {s}\",\"author\":{{\"name\":\"bev\"}},\"createdAt\":\"2026-08-12T02:00:00Z\"}}]", .{ pad_s, pad_s });
    defer gpa.free(comments);
    const folded = shapes.slim(gpa, comments) orelse return error.ExpectedCommentSlim;
    defer gpa.free(folded);
    try std.testing.expect(std.mem.indexOf(u8, folded, "\"n\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded, "bev") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded, "ada") == null);
    try std.testing.expect(std.mem.indexOf(u8, folded, "old ") == null);
    try std.testing.expect(std.mem.indexOf(u8, folded, pad_s) == null);
}

test "a direct call's slim result names a handle holding the full payload; an rlm bind stays plain JSON" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pad: [900]u8 = @splat('x');
    const fat = try std.fmt.allocPrint(gpa, "[{{\"id\":\"ISS-1\",\"title\":\"Login\",\"description\":\"{s}\",\"state\":\"open\"}}]", .{@as([]const u8, &pad)});
    const fat_len = fat.len;
    const kept = shapes.takeSlimKept(gpa, .{ .io = io, .dir = tmp.dir }, fat);
    defer gpa.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "ISS-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"state\"") == null); // dropped from the slim view...
    const at = std.mem.indexOf(u8, kept, "handle tr_") orelse return error.MissingHandle;
    const id_end = std.mem.indexOfScalarPos(u8, kept, at + 7, ' ') orelse return error.MissingHandle;
    const rel = try std.fmt.allocPrint(gpa, ".graff/tool-results/{s}.txt", .{kept[at + 7 .. id_end]});
    defer gpa.free(rel);
    const whole = try tmp.dir.readFileAlloc(io, rel, gpa, .limited(1 << 20));
    defer gpa.free(whole);
    try std.testing.expectEqual(fat_len, whole.len); // ...but kept whole behind the handle
    try std.testing.expect(std.mem.indexOf(u8, whole, "\"state\":\"open\"") != null);

    const bind_src = try std.fmt.allocPrint(gpa, "[{{\"id\":\"ISS-2\",\"title\":\"T\",\"description\":\"{s}\"}}]", .{@as([]const u8, &pad)});
    const bind = shapes.takeSlimKept(gpa, null, bind_src);
    defer gpa.free(bind);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bind, .{}); // rlm parses binds as JSON
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, bind, "handle") == null);
}
