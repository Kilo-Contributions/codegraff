//! A piped (non-TTY) REPL reads one prompt per line. A driver with a
//! multi-line prompt frames it the way a terminal frames a paste,
//! ESC[200~ … ESC[201~, and the whole block is one prompt, newlines kept
//! (ADR 0231). Without the frame each line is still its own prompt.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

/// The next prompt, or null at EOF. The result lives in `buf` (or the
/// reader's buffer) until the next call. Text after the end marker on its
/// line is dropped: a terminal sends only the Enter there. EOF inside an open
/// paste ends the prompt where the input ended.
pub fn next(in: *Io.Reader, gpa: Allocator, buf: *std.ArrayList(u8)) !?[]const u8 {
    const first = (try in.takeDelimiter('\n')) orelse return null;
    if (!std.mem.startsWith(u8, first, paste_start)) return first;
    buf.clearRetainingCapacity();
    var line = first[paste_start.len..];
    while (true) {
        if (std.mem.indexOf(u8, line, paste_end)) |end| {
            try buf.appendSlice(gpa, line[0..end]);
            return buf.items;
        }
        try buf.appendSlice(gpa, line);
        line = (try in.takeDelimiter('\n')) orelse return buf.items;
        try buf.append(gpa, '\n');
    }
}

test "a bracketed paste on a pipe is one prompt; bare lines stay one each (ADR 0231)" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var in: Io.Reader = .fixed("first\n\x1b[200~Create hello.txt\nThen rename it.\x1b[201~\nlast\n\x1b[200~open at EOF\ntail");
    try std.testing.expectEqualStrings("first", (try next(&in, gpa, &buf)).?);
    try std.testing.expectEqualStrings("Create hello.txt\nThen rename it.", (try next(&in, gpa, &buf)).?);
    try std.testing.expectEqualStrings("last", (try next(&in, gpa, &buf)).?);
    try std.testing.expectEqualStrings("open at EOF\ntail", (try next(&in, gpa, &buf)).?);
    try std.testing.expect(try next(&in, gpa, &buf) == null);
}
