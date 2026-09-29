
test "sleepText names the cap when a longer pause was requested" {
    const plain = try sleepText(std.testing.allocator, 40, 40);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("slept 40ms", plain);
    const capped = try sleepText(std.testing.allocator, 300_000, 5_000);
    defer std.testing.allocator.free(capped);
    try std.testing.expect(std.mem.indexOf(u8, capped, "not the 300000ms requested") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "clock_sleep") != null);
}
