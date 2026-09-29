
test "question aliases and a double-encoded argument string are read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Ship it?", (try run(a, "{\"prompt\":\"Ship it?\",\"options\":[\"yes\",\"no\"]}")).question.?);
    const enc = try run(a, "\"{\\\"question\\\":\\\"Which one?\\\",\\\"options\\\":[\\\"a\\\",\\\"b\\\"]}\"");
    try testing.expectEqualStrings("Which one?", enc.question.?);
    try testing.expectEqual(@as(usize, 2), enc.input.object.get("options").?.array.items.len);
    const plain = try run(a, "\"Proceed with the migration?\"");
    try testing.expectEqualStrings("Proceed with the migration?", plain.question.?);
    try testing.expectEqualStrings("Proceed with the migration?", plain.input.object.get("question").?.string);
}
