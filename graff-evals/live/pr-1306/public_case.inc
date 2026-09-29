
test "a whole citation marker is removed and plain text passes through untouched" {
    defer endTurn("s-whole");
    const plain = filter("s-whole", .message, "no markers here");
    defer plain.deinit();
    try std.testing.expect(plain.owned == null);
    try std.testing.expectEqualStrings("no markers here", plain.text);
    const cited = filter("s-whole", .message, "Rotate them first. \u{E200}cite\u{E202}turn3search0\u{E201}");
    defer cited.deinit();
    try std.testing.expectEqualStrings("Rotate them first. ", cited.text);
}
