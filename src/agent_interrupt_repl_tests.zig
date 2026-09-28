//! Focused regressions for the public Esc scanner seam (#967).

const std = @import("std");
const interrupt = @import("agent_interrupt.zig");
const main_mod = @import("main.zig");
const repl_glue = @import("repl_glue.zig");
const job_wait = @import("job_wait.zig");

const page = std.heap.page_allocator;

const FakeInput = struct {
    chunks: []const []const u8,
    next_chunk: usize = 0,
    poll_calls: usize = 0,

    pub fn read(self: *FakeInput, buf: []u8) usize {
        if (self.next_chunk >= self.chunks.len) return 0;
        const chunk = self.chunks[self.next_chunk];
        self.next_chunk += 1;
        std.debug.assert(chunk.len <= buf.len);
        @memcpy(buf[0..chunk.len], chunk);
        return chunk.len;
    }

    pub fn poll(self: *FakeInput, timeout_ms: i32) bool {
        self.poll_calls += 1;
        return timeout_ms == 50 and self.next_chunk < self.chunks.len;
    }
};

fn resetGlobals() void {
    for (main_mod.g_steer_queue.items) |entry| page.free(entry.text);
    main_mod.g_steer_queue.clearRetainingCapacity();
    repl_glue.resetSteerPartial();
    main_mod.g_steer_echoed = false;
    main_mod.g_steer_visible.store(false, .release);
    main_mod.g_force_interrupt = false;
    main_mod.g_thinking_fold_request = false;
    main_mod.g_thinking_open = false;
    job_wait.followup_pending.store(false, .release);
}

test "same-read ESC DEL edits steering without interrupting" {
    resetGlobals();
    defer resetGlobals();

    try main_mod.g_steer_buf.appendSlice(page, "ab");
    var chunks = [_][]const u8{"\x1b\x7f"};
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("a", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 0), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}

test "split-read ESC DEL edits steering without interrupting" {
    resetGlobals();
    defer resetGlobals();

    try main_mod.g_steer_buf.appendSlice(page, "ab");
    var chunks = [_][]const u8{ "\x1b", "\x7f" };
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("a", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 1), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}

test "same-read ESC DEL removes one complete UTF-8 codepoint without interrupting" {
    resetGlobals();
    defer resetGlobals();

    try main_mod.g_steer_buf.appendSlice(page, "aé");
    var chunks = [_][]const u8{"\x1b\x7f"};
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("a", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 0), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}

test "split-read ESC DEL removes one complete UTF-8 codepoint without interrupting" {
    resetGlobals();
    defer resetGlobals();

    try main_mod.g_steer_buf.appendSlice(page, "aé");
    var chunks = [_][]const u8{ "\x1b", "\x7f" };
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("a", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 1), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}

test "lone ESC still interrupts" {
    resetGlobals();
    defer resetGlobals();

    var chunks = [_][]const u8{"\x1b"};
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqual(@as(usize, 1), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}

test "mid-turn bracketed multiline paste queues once only after Enter, not on pasted blank lines" {
    resetGlobals();
    defer resetGlobals();

    var begin = FakeInput{ .chunks = &.{"\x1b[20"} };
    try std.testing.expect(!interrupt.escPressedFrom(&begin, false));
    var body = FakeInput{ .chunks = &.{"0~first\n\n"} };
    try std.testing.expect(!interrupt.escPressedFrom(&body, false));
    const many: [256]u8 = @splat('x');
    var middle = FakeInput{ .chunks = &.{many[0..]} };
    try std.testing.expect(!interrupt.escPressedFrom(&middle, false));
    var end_head = FakeInput{ .chunks = &.{"\r\nlast\x1b"} };
    try std.testing.expect(!interrupt.escPressedFrom(&end_head, false));
    try std.testing.expectEqual(@as(usize, 0), main_mod.g_steer_queue.items.len);
    var end_tail = FakeInput{ .chunks = &.{"[201~"} };
    try std.testing.expect(!interrupt.escPressedFrom(&end_tail, false));
    try std.testing.expectEqual(@as(usize, 0), main_mod.g_steer_queue.items.len);

    var submit = FakeInput{ .chunks = &.{"\r\n"} };
    try std.testing.expect(!interrupt.escPressedFrom(&submit, false));
    try std.testing.expectEqual(@as(usize, 1), main_mod.g_steer_queue.items.len);
    const entry = main_mod.g_steer_queue.items[0];
    try std.testing.expect(!entry.force);
    try std.testing.expect(std.mem.startsWith(u8, entry.text, "first\n\n"));
    try std.testing.expect(std.mem.endsWith(u8, entry.text, "\nlast"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, entry.text, "\n"));
    try std.testing.expectEqual(@as(usize, 7 + 256 + 1 + 4), entry.text.len);

    var force = FakeInput{ .chunks = &.{"\r"} };
    try std.testing.expect(interrupt.escPressedFrom(&force, false));
    try std.testing.expect(main_mod.g_steer_queue.items[0].force);
    try std.testing.expect(main_mod.g_force_interrupt);
}
