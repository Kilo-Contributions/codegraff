
test "a cut-off Anthropic tool input is refused, not run as {} (#1218)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cut: std.json.ObjectMap = .empty;
    try putStreamedInput(arena, &cut, "{\"path\":\"src/ma");
    try std.testing.expectEqual(@as(usize, 0), cut.get("input").?.object.count());
    try std.testing.expect(takeInvalidMark(&cut));
    try std.testing.expect(cut.get(invalid_mark) == null); // never replayed
    var whole: std.json.ObjectMap = .empty;
    try putStreamedInput(arena, &whole, "{\"path\":\"src/main.zig\"}");
    try std.testing.expect(!takeInvalidMark(&whole));
    try std.testing.expectEqualStrings("src/main.zig", whole.get("input").?.object.get("path").?.string);
}
