
test "shutdown frees a filled cache and is a no-op when empty (#1196)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    shutdown(io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    store.mu.lockUncancelable(io);
    putUnlocked(gpa, arena_state.allocator(), "linear_issues", "{\"type\":\"object\"}");
    store.mu.unlock(io);
    try std.testing.expectEqual(@as(usize, 1), store.map.count());
    shutdown(io); // testing.allocator fails the test on anything left behind
    try std.testing.expectEqual(@as(usize, 0), store.map.count());
    try std.testing.expect(store.gpa == null);
    shutdown(io);
}
