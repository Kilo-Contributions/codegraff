
test "records larger than the reader buffer are returned whole" {
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 200 * 1024);
    defer gpa.free(big);
    @memset(big, 'a');
    const input = try std.mem.concat(gpa, u8, &.{ "{\"id\":1}\n", big, "\n{\"id\":2}" });
    defer gpa.free(input);
    // A 64-byte buffer in front of the source, like the 64 KiB stdin buffer in
    // front of a 200 KiB+ ACP prompt.
    var src: Io.Reader = .fixed(input);
    var buf: [64]u8 = undefined;
    var ri: std.testing.ReaderIndirect = .init(&src, &buf);
    const r = &ri.interface;
    const first = try take(r, gpa, max_bytes);
    defer gpa.free(first.line);
    try std.testing.expectEqualStrings("{\"id\":1}", first.line);
    const second = try take(r, gpa, max_bytes);
    defer gpa.free(second.line);
    try std.testing.expectEqual(big.len, second.line.len);
    const third = try take(r, gpa, max_bytes);
    defer gpa.free(third.line);
    try std.testing.expectEqualStrings("{\"id\":2}", third.line);
    try std.testing.expect((try take(r, gpa, max_bytes)) == .eof);
}
