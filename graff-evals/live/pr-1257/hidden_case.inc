
test "an over-limit record is dropped and the next one still arrives" {
    const gpa = std.testing.allocator;
    var r: Io.Reader = .fixed("0123456789abcdef\n{\"ok\":true}\n");
    try std.testing.expect((try take(&r, gpa, 8)) == .too_long);
    const next = try take(&r, gpa, 8 * 1024);
    defer gpa.free(next.line);
    try std.testing.expectEqualStrings("{\"ok\":true}", next.line);
    try std.testing.expect((try take(&r, gpa, 8)) == .eof);
}
