
test "usage_update carries used and size, and cost only when known" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try write(&w, "s1", 53000, 200000, null);
    const plain = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, plain, "\"sessionUpdate\":\"usage_update\",\"used\":53000,\"size\":200000}") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "cost") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "gui_context_meter") == null);
    w = .fixed(&buf);
    try write(&w, "s1", 1, 2, 0.045);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"cost\":{\"amount\":0.045,\"currency\":\"USD\"}") != null);
}
