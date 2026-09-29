
test "the schema shape passes through unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try run(arena.allocator(), "{\"question\":\"Which target?\",\"options\":[\"npm\",\"GitHub\"]}");
    try testing.expectEqualStrings("Which target?", got.question.?);
    const opts = got.input.object.get("options").?.array.items;
    try testing.expectEqualStrings("GitHub", opts[1].string);
}
