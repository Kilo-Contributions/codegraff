
test "noAnswerText keeps cancel as cancel and never calls a lost question a cancel (#1322)" {
    try std.testing.expectEqualStrings("user cancelled the follow-up", noAnswerText(.dismissed));
    try std.testing.expect(std.mem.indexOf(u8, noAnswerText(.unanswered), "cancel") == null);
    try std.testing.expect(std.mem.indexOf(u8, noAnswerText(.unanswered), "not a refusal") != null);
    try std.testing.expect(std.mem.indexOf(u8, noAnswerText(.declined), "declined") != null);
}
