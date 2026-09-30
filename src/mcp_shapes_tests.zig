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
