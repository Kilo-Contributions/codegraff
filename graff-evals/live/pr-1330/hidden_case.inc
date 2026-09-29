
test "recoverInlineCalls (#1247): quoted, unwrapped, unknown, or malformed markup stays text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const block = "<tool_call><function=read_file><parameter=path>a.zig</parameter></function></tool_call>";
    for ([_][]const u8{
        "Example: `" ++ block ++ "`",
        "```\n" ++ block ++ "\n```",
        "<function=read_file><parameter=path>a.zig</parameter></function>",
        "<tool_call><function=shell><parameter=command>ls</parameter></function></tool_call>",
        "<tool_call><function=read_file><parameter=nope>x</parameter></function></tool_call>",
        "<tool_call><function=read_file><parameter=path>a.zig</parameter></tool_call>",
    }) |content| {
        var message = try inlineMessage(a, content);
        try std.testing.expect(!try repair.recoverInlineCalls(a, a, &message, inline_tools));
        try std.testing.expectEqualStrings(content, message.object.get("content").?.string);
        try std.testing.expect(message.object.get("tool_calls") == null);
    }
}
