
test "a read-only child keeps reads and read-only shell, not writes (#1360)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const call = struct {
        fn f(al: std.mem.Allocator, name: []const u8, input: []const u8) ToolCall {
            const v = std.json.parseFromSliceLeaky(std.json.Value, al, input, .{}) catch unreachable;
            return .{ .id = "c", .name = name, .input = v };
        }
    }.f;
    try std.testing.expect(readOnlyChildAllows(call(a, "read_file", "{\"path\":\"src/main.zig\"}")));
    try std.testing.expect(readOnlyChildAllows(call(a, "bash", "{\"command\":\"ls src\"}")));
    try std.testing.expect(readOnlyChildAllows(call(a, "bash", "{\"action\":\"output\",\"id\":3}")));
    try std.testing.expect(!readOnlyChildAllows(call(a, "write_file", "{\"path\":\"a\",\"content\":\"b\"}")));
    try std.testing.expect(!readOnlyChildAllows(call(a, "edit_file", "{}")));
    try std.testing.expect(!readOnlyChildAllows(call(a, "bash", "{\"command\":\"rm -rf build\"}")));
}
