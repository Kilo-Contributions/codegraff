
test "recoverInlineCalls (#1247): markup after prose becomes calls, parameters in any order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var message = try inlineMessage(a, "Reading both.\n<tool_call><function=read_file><parameter=start_line>40</parameter><parameter=path>a.zig</parameter></function></tool_call>\n" ++
        "<tool_call>\n<function=todo_read>\n</function>\n</tool_call>");
    try std.testing.expect(try repair.recoverInlineCalls(a, a, &message, inline_tools));
    try std.testing.expectEqual(@as(usize, 2), message.object.get("tool_calls").?.array.items.len);
    try std.testing.expectEqualStrings("read_file", callName(message, 0));
    const args = try std.json.parseFromSliceLeaky(Value, a, callArgs(message, 0), .{});
    try std.testing.expectEqualStrings("a.zig", args.object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 40), args.object.get("start_line").?.integer);
    try std.testing.expectEqualStrings("todo_read", callName(message, 1));
    try std.testing.expectEqualStrings("{}", callArgs(message, 1));
    const id0 = message.object.get("tool_calls").?.array.items[0].object.get("id").?.string;
    const id1 = message.object.get("tool_calls").?.array.items[1].object.get("id").?.string;
    try std.testing.expect(!std.mem.eql(u8, id0, id1));
    try std.testing.expectEqualStrings("Reading both.", message.object.get("content").?.string);

    var only = try inlineMessage(a, "<tool_call><function=todo_read></function></tool_call>");
    try std.testing.expect(try repair.recoverInlineCalls(a, a, &only, inline_tools));
    try std.testing.expect(only.object.get("content").? == .null);
}
