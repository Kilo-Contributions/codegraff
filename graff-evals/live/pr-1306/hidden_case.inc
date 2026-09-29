
test "a marker split across deltas leaves no cite or turn words behind" {
    defer endTurn("s-split");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    // Split inside the word, and inside the UTF-8 bytes of a marker glyph.
    for ([_][]const u8{ "Done.\u{E200}ci", "te\u{E202}turn3sea", "rch0\xee", "\x88\x81 Next." }) |chunk|
        try collect(&buf, "s-split", .message, chunk);
    try std.testing.expectEqualStrings("Done. Next.", buf.items);
}
