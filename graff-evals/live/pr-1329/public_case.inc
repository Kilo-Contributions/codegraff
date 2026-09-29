
test "joinWithin (#1291): a server that fails fast ends the wait early" {
    const io = std.testing.io;
    var reg = mcp.Registry.empty(std.testing.allocator, io);
    defer reg.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const specs = [_]Spec{try stdioSpec(a, "gone", "/nonexistent/graff-mcp-1291", &.{})};
    const t0 = std.Io.Timestamp.now(io, .awake);
    try std.testing.expect(!joinWithin(&reg, a, &specs, 10_000));
    try std.testing.expect(t0.untilNow(io, .awake).toMilliseconds() < 5_000);
    try std.testing.expectEqual(@as(usize, 0), reg.servers.len);
}
