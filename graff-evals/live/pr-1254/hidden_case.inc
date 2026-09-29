
test "parse: no params, no list, or an empty list is nothing to connect" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, null)).len);
    const none = try std.json.parseFromSliceLeaky(Value, a, "{\"cwd\":\"/tmp\"}", .{});
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, none)).len);
    const empty = try std.json.parseFromSliceLeaky(Value, a, "{\"mcpServers\":[]}", .{});
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, empty)).len);
}
