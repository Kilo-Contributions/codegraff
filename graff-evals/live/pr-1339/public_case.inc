
test "decline, cancel, an empty accept and an error each end the question as themselves (#1322)" {
    acp_ask.attach(testing.io, testing.allocator);
    defer acp_ask.detach();
    defer finish();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { result: []const u8, want: acp_ask.Outcome }{
        .{ .result = "\"result\":{\"action\":\"decline\"}", .want = .declined },
        .{ .result = "\"result\":{\"action\":\"cancel\"}", .want = .dismissed },
        .{ .result = "\"result\":{\"action\":\"accept\",\"content\":{}}", .want = .unanswered },
        .{ .result = "\"result\":{\"action\":\"accept\",\"content\":{\"answer\":\"  \"}}", .want = .unanswered },
        .{ .result = "\"error\":{\"code\":-32601,\"message\":\"no\"}", .want = .unanswered },
    };
    for (cases) |c| {
        var sink: Io.Writer.Allocating = .init(a);
        try writeRequest(&sink.writer, "s", "q", .null);
        const line = try std.fmt.allocPrint(a, "{{\"id\":\"graff-elicit-{d}\",{s}}}", .{ pending.load(.acquire), c.result });
        try testing.expect(accept(try parse(a, line)));
        const got = try acp_ask.wait(a);
        try testing.expect(got.cancelled);
        try testing.expectEqual(c.want, got.outcome);
    }
}
