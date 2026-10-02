//! Origin-aware bracketed-paste finalization for the TUI composer (#792).
//!
//! The decoder owns paste framing. This module owns the exact inserted range:
//! text receives a removable trailing separator, pasted file paths become
//! semantic spans, and an image consumes only its own pasted bytes.

const std = @import("std");
const app = @import("app.zig");
const dispatch = @import("dispatch.zig");
const image = @import("image.zig");
const Model = app.Model;

pub fn begin(self: *Model) void {
    self.input.beginPaste();
}

pub fn finish(self: *Model) void {
    const range = self.input.pasteRange() orelse {
        self.input.endPaste();
        return;
    };
    defer self.input.endPaste();
    const raw = self.input.getValue()[range.start..range.end];
    // Rich clipboard selections can reach the terminal as only blank lines,
    // NBSP, or object/format markers. They are not a usable text attachment.
    if (!hasContent(raw)) {
        if (range.start != range.end and !self.input.replacePaste(range, "", false)) return;
        recoverImage(self);
        return;
    }
    const path = normalizePath(self.alloc, raw) orelse {
        self.input.ensurePasteSeparator();
        return;
    };
    defer self.alloc.free(path);

    if (dispatch.looksLikeImagePath(path) and image.attachDropped(self, path)) {
        _ = self.input.replacePaste(range, "", false);
        return;
    }
    if (!pathExists(path)) {
        self.input.ensurePasteSeparator();
        return;
    }
    if (self.input.replacePaste(range, path, true)) self.input.ensurePasteSeparator();
}

fn recoverImage(self: *Model) void {
    const engine = @import("engine.zig");
    if (engine.g_paste_fn) |f| {
        var buf: [1024]u8 = undefined;
        var owned = false;
        const n = f(engine.g_turn_ctx, &buf, &owned);
        if (n > 0) {
            const before = self.images.items.len;
            @import("owned_images.zig").attach(self, buf[0..@intCast(n)], owned);
            if (self.images.items.len > before) return;
        } else if (n < 0) {
            self.setToast(buf[0..@intCast(-n)]);
            return;
        }
    }
    self.setToast("paste contained no usable text or image — copy the image itself or use /image <path>");
}

fn hasContent(raw: []const u8) bool {
    const view = std.unicode.Utf8View.init(raw) catch return true;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            0...0x20,
            0x7f...0xa0,
            0xad,
            0x61c,
            0x1680,
            0x180e,
            0x2000...0x200f,
            0x2028...0x202f,
            0x205f...0x206f,
            0x3000,
            0xfeff,
            0xfff9...0xfffc,
            => {},
            else => return true,
        }
    }
    return false;
}

fn pathExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Normalize the one-path forms terminals emit for Finder paste/drop. Mixed
/// prose and multiline payloads remain ordinary pasted text.
fn normalizePath(alloc: std.mem.Allocator, raw: []const u8) ?[]u8 {
    var src = std.mem.trim(u8, raw, " \t\r\n");
    if (src.len < 2 or std.mem.indexOfAny(u8, src, "\r\n") != null) return null;
    if ((src[0] == '\'' and src[src.len - 1] == '\'') or (src[0] == '"' and src[src.len - 1] == '"')) {
        src = src[1 .. src.len - 1];
    }
    if (std.mem.startsWith(u8, src, "file://")) src = src["file://".len..];

    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == 0 or (c < 0x20 and c != '\t')) return null;
        if (c == '%' and i + 2 < src.len) {
            const hi = hexNibble(src[i + 1]);
            const lo = hexNibble(src[i + 2]);
            if (hi != null and lo != null) {
                const decoded = (hi.? << 4) | lo.?;
                if (decoded == 0 or decoded < 0x20) return null;
                out.append(decoded) catch return null;
                i += 3;
                continue;
            }
        }
        if (c == '\\' and i + 1 < src.len) {
            out.append(src[i + 1]) catch return null;
            i += 2;
            continue;
        }
        out.append(c) catch return null;
        i += 1;
    }
    if (out.items.len == 0 or out.items[0] != '/') return null;
    return out.toOwnedSlice() catch null;
}

const TestPaste = struct {
    payload: []const u8 = "",
    failed: bool = false,
    calls: usize = 0,

    fn call(ctx: ?*anyopaque, dest: []u8, owned: *bool) isize {
        const self: *TestPaste = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        owned.* = false;
        @memcpy(dest[0..self.payload.len], self.payload);
        const n: isize = @intCast(self.payload.len);
        return if (self.failed) -n else n;
    }
};

test "#1468 empty and format-only terminal pastes warn without a false text chip" {
    const engine = @import("engine.zig");
    const saved_fn = engine.g_paste_fn;
    const saved_ctx = engine.g_turn_ctx;
    defer {
        engine.g_paste_fn = saved_fn;
        engine.g_turn_ctx = saved_ctx;
    }
    var callback = TestPaste{};
    engine.g_paste_fn = TestPaste.call;
    engine.g_turn_ctx = &callback;
    for ([_][]const u8{ "", "\n\n\n", " \t\r\n", "\u{a0}\u{200b}\u{feff}\u{fffc}\n\n\n" }) |payload| {
        var term: @import("sim.zig").Term = undefined;
        term.init(std.testing.allocator, 120, 24);
        defer term.deinit();
        _ = term.typeText("beforeafter");
        term.model.input.cursor = "before".len;
        _ = term.feed("\x1b[200~");
        _ = term.feed(payload);
        _ = term.feed("\x1b[201~");
        try std.testing.expectEqualStrings("beforeafter", term.model.input.getValue());
        try std.testing.expectEqual(@as(usize, 6), term.model.input.cursor);
        try std.testing.expectEqual(@as(usize, 0), term.model.images.items.len);
        const screen = try term.screen();
        defer term.alloc.free(screen);
        try std.testing.expect(std.mem.indexOf(u8, screen, "paste contained no usable text or image") != null);
        try std.testing.expect(std.mem.indexOf(u8, screen, "[Pasted text") == null);
    }
    try std.testing.expectEqual(@as(usize, 4), callback.calls);
}

test "#1468 format-only paste recovers an image through the live callback" {
    const engine = @import("engine.zig");
    const saved_fn = engine.g_paste_fn;
    const saved_ctx = engine.g_turn_ctx;
    defer {
        engine.g_paste_fn = saved_fn;
        engine.g_turn_ctx = saved_ctx;
    }
    var callback = TestPaste{ .payload = "/synthetic/clipboard.png" };
    engine.g_paste_fn = TestPaste.call;
    engine.g_turn_ctx = &callback;
    var term: @import("sim.zig").Term = undefined;
    term.init(std.testing.allocator, 120, 24);
    defer term.deinit();
    _ = term.typeText("describe this");
    _ = term.feed("\x1b[200~\n\n\n\x1b[201~");
    try std.testing.expectEqualStrings("describe this", term.model.input.getValue());
    try std.testing.expectEqual(@as(usize, 1), callback.calls);
    try std.testing.expectEqual(@as(usize, 1), term.model.images.items.len);
    try std.testing.expectEqualStrings(callback.payload, term.model.images.items[0]);
}

test "#1468 recovery keeps actionable errors and never probes the clipboard for real text" {
    const engine = @import("engine.zig");
    const saved_fn = engine.g_paste_fn;
    const saved_ctx = engine.g_turn_ctx;
    defer {
        engine.g_paste_fn = saved_fn;
        engine.g_turn_ctx = saved_ctx;
    }
    var callback = TestPaste{ .payload = "clipboard image export failed", .failed = true };
    engine.g_paste_fn = TestPaste.call;
    engine.g_turn_ctx = &callback;
    var term: @import("sim.zig").Term = undefined;
    term.init(std.testing.allocator, 120, 24);
    defer term.deinit();
    _ = term.feed("\x1b[200~\n\n\n\x1b[201~");
    const screen = try term.screen();
    defer term.alloc.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, callback.payload) != null);
    try std.testing.expectEqualStrings("", term.model.input.getValue());
    const text = "\n\u{200d}hello\u{a0}\nworld\n";
    _ = term.feed("\x1b[200~");
    _ = term.feed(text);
    _ = term.feed("\x1b[201~");
    try std.testing.expectEqualStrings(text, term.model.input.getValue());
    try std.testing.expectEqual(@as(usize, 1), callback.calls);
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
