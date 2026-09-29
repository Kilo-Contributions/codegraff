
test "joinWithin (#1291): a stalled handshake returns at the budget and stays queued" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // needs /bin/sh
    const io = std.testing.io;
    var reg = mcp.Registry.empty(std.testing.allocator, io);
    defer reg.deinit(); // joins the handshake once `sleep` exits
    reg.stdio_probe = false;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    // Starts fine and never answers the initialize request.
    const specs = [_]Spec{try stdioSpec(a, "stalled", "/bin/sh", &.{ "-c", "sleep 2" })};
    const t0 = std.Io.Timestamp.now(io, .awake);
    try std.testing.expect(!joinWithin(&reg, a, &specs, 100));
    try std.testing.expect(t0.untilNow(io, .awake).toMilliseconds() < 1_500);
    try std.testing.expect(@import("mcp_boot.zig").alreadyStarting(&reg, "stalled"));
}
