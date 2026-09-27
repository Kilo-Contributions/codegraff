//! ACP text without provider citation markers.
//!
//! With hosted web search, GPT models cite results with private-use markers
//! such as `\u{E200}cite\u{E202}turn3search0\u{E201}`. graff's own TUI strips
//! them on the client side (tui_acp_updates.zig), so every other ACP client
//! rendered them as boxes plus stray words. Filtering where agent text leaves
//! over ACP keeps every client 1:1 with the terminal.
//!
//! The filter is stateful per session and channel: a streamed marker can
//! straddle two deltas, and a per-chunk strip would leave `cite` and
//! `turn3search0` visible. The session transcript keeps the provider payload.

const std = @import("std");
const cite_markup = @import("cite_markup.zig");

pub const Channel = enum { message, thought };

const Slot = struct {
    used: bool = false,
    key: u64 = 0,
    channel: Channel = .message,
    stream: cite_markup.Stream = .{},
};

// Sessions a single ACP process streams at once (root plus live children).
// When all are taken the oldest slot is reused; the worst case is one marker
// split across that session's next two deltas.
const max_slots = 64;
var slots: [max_slots]Slot = @splat(.{});
var next_evict: usize = 0;
var lock: std.atomic.Value(bool) = .init(false);

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release() void {
    lock.store(false, .release);
}

fn keyOf(session_id: []const u8) u64 {
    return std.hash.Wyhash.hash(0, session_id);
}

fn find(key: u64, channel: Channel) ?*Slot {
    for (&slots) |*slot| if (slot.used and slot.key == key and slot.channel == channel) return slot;
    return null;
}

fn claim(key: u64, channel: Channel) *Slot {
    const slot = for (&slots) |*s| {
        if (!s.used) break s;
    } else blk: {
        const s = &slots[next_evict];
        next_evict = (next_evict + 1) % max_slots;
        break :blk s;
    };
    slot.* = .{ .used = true, .key = key, .channel = channel };
    return slot;
}

pub const Cleaned = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: Cleaned) void {
        if (self.owned) |buf| std.heap.page_allocator.free(buf);
    }
};

/// `text` with citation markers removed, continuing any marker the previous
/// chunk on this session and channel left open. Allocates only when a marker
/// byte is present or one is still open.
pub fn filter(session_id: []const u8, channel: Channel, text: []const u8) Cleaned {
    acquire();
    defer release();
    const key = keyOf(session_id);
    const existing = find(key, channel);
    const idle = if (existing) |s| s.stream.pending == 0 and !s.stream.in_annotation else true;
    if (idle and std.mem.indexOfScalar(u8, text, 0xEE) == null) return .{ .text = text };
    const slot = existing orelse claim(key, channel);
    // Each byte emits at most itself plus the (at most two) held lead bytes.
    const buf = std.heap.page_allocator.alloc(u8, text.len + 2) catch return .{ .text = text };
    var n: usize = 0;
    var out: [3]u8 = undefined;
    for (text) |b| {
        const piece = slot.stream.byte(b, &out);
        @memcpy(buf[n..][0..piece.len], piece);
        n += piece.len;
    }
    return .{ .text = buf[0..n], .owned = buf };
}

/// Stateless strip for text that is complete on its own (replayed history).
pub fn whole(text: []const u8) Cleaned {
    if (!cite_markup.contains(text)) return .{ .text = text };
    const buf = cite_markup.dupe(std.heap.page_allocator, text) catch return .{ .text = text };
    return .{ .text = buf, .owned = buf };
}

/// A turn is over: forget this session's open markers so the next turn
/// starts clean. An unfinished marker at the end of a turn is dropped.
pub fn endTurn(session_id: []const u8) void {
    acquire();
    defer release();
    const key = keyOf(session_id);
    for (&slots) |*slot| if (slot.used and slot.key == key) {
        slot.* = .{};
    };
}

fn collect(buf: *std.ArrayList(u8), session_id: []const u8, channel: Channel, chunk: []const u8) !void {
    const cleaned = filter(session_id, channel, chunk);
    defer cleaned.deinit();
    try buf.appendSlice(std.testing.allocator, cleaned.text);
}

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

test "a marker split across deltas leaves no cite or turn words behind" {
    defer endTurn("s-split");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    // Split inside the word, and inside the UTF-8 bytes of a marker glyph.
    for ([_][]const u8{ "Done.\u{E200}ci", "te\u{E202}turn3sea", "rch0\xee", "\x88\x81 Next." }) |chunk|
        try collect(&buf, "s-split", .message, chunk);
    try std.testing.expectEqualStrings("Done. Next.", buf.items);
}

test "channels and sessions keep separate state" {
    defer endTurn("s-a");
    defer endTurn("s-b");
    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(std.testing.allocator);
    var thought: std.ArrayList(u8) = .empty;
    defer thought.deinit(std.testing.allocator);
    var other: std.ArrayList(u8) = .empty;
    defer other.deinit(std.testing.allocator);
    try collect(&answer, "s-a", .message, "A\u{E200}cite\u{E202}tu");
    try collect(&thought, "s-a", .thought, "thinking");
    try collect(&other, "s-b", .message, "other session");
    try collect(&answer, "s-a", .message, "rn0search1\u{E201}B");
    try std.testing.expectEqualStrings("AB", answer.items);
    try std.testing.expectEqualStrings("thinking", thought.items);
    try std.testing.expectEqualStrings("other session", other.items);
}

test "other private-use glyphs are kept" {
    defer endTurn("s-pua");
    const kept = filter("s-pua", .message, "icon \u{E000} and \u{E1FF}");
    defer kept.deinit();
    try std.testing.expectEqualStrings("icon \u{E000} and \u{E1FF}", kept.text);
}

test "endTurn drops an unfinished marker so the next turn starts clean" {
    const open = filter("s-end", .message, "tail \u{E200}cite\u{E202}turn9");
    defer open.deinit();
    try std.testing.expectEqualStrings("tail ", open.text);
    endTurn("s-end");
    const next = filter("s-end", .message, "fresh text");
    defer next.deinit();
    try std.testing.expect(next.owned == null);
    try std.testing.expectEqualStrings("fresh text", next.text);
}

test "whole strips replayed history without session state" {
    const cleaned = whole("History \u{E200}cite\u{E202}turn0view0\u{E201}line");
    defer cleaned.deinit();
    try std.testing.expectEqualStrings("History line", cleaned.text);
}
