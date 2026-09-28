//! Mid-turn line-REPL stdin framing. Bracketed paste is one draft until the
//! terminal's end marker; only a real Enter after that marker queues it.
const std = @import("std");
const main_mod = @import("main.zig");
const repl_glue = @import("repl_glue.zig");
const state = @import("steer_input_state.zig");
const style = &@import("ansi.zig").style;
const page = std.heap.page_allocator;

/// `input.read` is nonblocking and returns at most buf.len bytes; `poll`
/// supplies a short continuation for split terminal control sequences.
pub fn scan(input: anytype, echo: bool) bool {
    state.lock();
    defer state.unlock();
    var buf: [256]u8 = undefined;
    var found = feed(buf[0..input.read(&buf)], echo);
    var pulls: usize = 0;
    while (state.scan.mode != .normal and pulls < 4 and input.poll(50)) : (pulls += 1) {
        const n = input.read(&buf);
        if (n == 0) break;
        found = feed(buf[0..n], echo) or found;
    }
    if (state.scan.mode == .esc and !state.scan.in_paste) {
        state.scan.mode = .normal;
        main_mod.g_force_interrupt = false;
        found = true;
    }
    return found;
}

fn feed(bytes: []const u8, echo: bool) bool {
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    var found = false;
    for (bytes) |c| {
        switch (state.scan.mode) {
            .normal => {
                if (c == 0x1b) {
                    state.scan.mode = .esc;
                    state.scan.entered_cr = false;
                } else found = normalByte(c, echo) or found;
            },
            .esc => {
                state.scan.mode = .normal;
                switch (c) {
                    '[' => {
                        state.scan.mode = .csi;
                        state.scan.csi_len = 0;
                    },
                    'O' => state.scan.mode = .ss3,
                    ']' => state.scan.mode = .osc,
                    else => {
                        // ESC DEL/BS is a modified deletion, not cancellation.
                        if (!state.scan.in_paste and c != 0x7f and c != 0x08) {
                            main_mod.g_force_interrupt = false;
                            found = true;
                        }
                        if (c == 0x1b) state.scan.mode = .esc else found = normalByte(c, echo) or found;
                    },
                }
            },
            .csi => {
                if (state.scan.csi_len < state.scan.csi.len) {
                    state.scan.csi[state.scan.csi_len] = c;
                    state.scan.csi_len += 1;
                }
                if (c >= 0x40 and c <= 0x7e) {
                    const seq = state.scan.csi[0..state.scan.csi_len];
                    if (std.mem.eql(u8, seq, "200~")) {
                        state.scan.in_paste = true;
                        state.scan.paste_bytes = 0;
                        state.scan.paste_lines = 1;
                        state.scan.pasted_cr = false;
                    } else if (std.mem.eql(u8, seq, "201~")) {
                        finishPaste(echo);
                    } else if (main_mod.g_thinking_open and std.mem.startsWith(u8, seq, "<0;") and c == 'M') {
                        main_mod.g_thinking_fold_request = true;
                    }
                    state.scan.mode = .normal;
                    state.scan.csi_len = 0;
                }
            },
            .ss3 => state.scan.mode = .normal,
            .osc => {
                if (c == 0x07) state.scan.mode = .normal else if (c == 0x1b) state.scan.mode = .osc_esc;
            },
            .osc_esc => {
                if (c == '\\' or c == 0x07) state.scan.mode = .normal else state.scan.mode = if (c == 0x1b) .osc_esc else .osc;
            },
        }
    }
    return found;
}

fn normalByte(c: u8, echo: bool) bool {
    if (state.scan.in_paste) {
        if (c == '\r') {
            appendPaste('\n');
            state.scan.pasted_cr = true;
        } else if (c == '\n') {
            if (!state.scan.pasted_cr) appendPaste('\n');
            state.scan.pasted_cr = false;
        } else {
            state.scan.pasted_cr = false;
            if (c >= 0x20 or c == '\t') appendPaste(c);
        }
        return false;
    }
    if (c == '\n' and state.scan.entered_cr) {
        state.scan.entered_cr = false;
        return false; // CRLF is one Enter, never a second force-Enter.
    }
    state.scan.entered_cr = c == '\r';
    if (c == '\n' or c == '\r') return enter(echo);
    if (c == 0x7f or c == 0x08) {
        const items = main_mod.g_steer_buf.items;
        if (items.len > 0) {
            var start = items.len - 1;
            while (start > 0 and items[start] & 0xc0 == 0x80) start -= 1;
            main_mod.g_steer_buf.shrinkRetainingCapacity(start);
            if (echo) repl_glue.steerEchoUnlocked("\x08 \x08");
        }
        return false;
    }
    if (c == 0x14) {
        main_mod.g_thinking_fold_request = true;
        return false;
    }
    if (c < 0x20) return false;
    main_mod.g_steer_buf.append(page, c) catch return false;
    if (echo) {
        startEcho();
        const one = [_]u8{c};
        repl_glue.steerEchoUnlocked(&one);
    }
    return false;
}

fn appendPaste(c: u8) void {
    main_mod.g_steer_buf.append(page, c) catch return;
    state.scan.paste_bytes += 1;
    if (c == '\n') state.scan.paste_lines += 1;
}

fn finishPaste(echo: bool) void {
    if (!state.scan.in_paste) return;
    state.scan.in_paste = false;
    if (echo and state.scan.paste_bytes > 0) {
        startEcho();
        var label: [80]u8 = undefined;
        const text = std.fmt.bufPrint(&label, "[Pasted text +{d} lines]", .{state.scan.paste_lines}) catch "[Pasted text]";
        repl_glue.steerEchoUnlocked(text);
    }
}

fn startEcho() void {
    if (main_mod.g_steer_echoed) return;
    main_mod.g_steer_visible.store(true, .release);
    repl_glue.steerEchoUnlocked("\n");
    repl_glue.steerEchoUnlocked(style.accent);
    repl_glue.steerEchoUnlocked("↳ steer ›");
    repl_glue.steerEchoUnlocked(style.reset);
    repl_glue.steerEchoUnlocked(" ");
    main_mod.g_steer_echoed = true;
}

fn enter(echo: bool) bool {
    var forced = false;
    if (main_mod.g_steer_buf.items.len > 0) {
        if (main_mod.g_steer_buf.toOwnedSlice(page)) |text| {
            if (repl_glue.steerFlushRedundant(main_mod.g_steer_queue.items, text)) {
                page.free(text);
            } else {
                if (main_mod.g_steer_queue.append(page, .{ .text = text, .force = false })) |_| {
                    @import("job_wait.zig").noteFollowup();
                } else |_| page.free(text);
            }
        } else |_| main_mod.g_steer_buf.clearRetainingCapacity();
        if (echo and main_mod.g_steer_echoed) {
            var label: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&label, "  \x1b[2m[queued · {d} waiting]\x1b[0m\n", .{main_mod.g_steer_queue.items.len}) catch "\n";
            repl_glue.steerEchoUnlocked(text);
        }
    } else if (main_mod.g_steer_queue.items.len > 0) {
        main_mod.g_steer_queue.items[0].force = true;
        main_mod.g_force_interrupt = true;
        forced = true;
        if (echo) {
            if (main_mod.g_steer_echoed) repl_glue.steerEchoUnlocked("\n");
            repl_glue.steerEchoUnlocked(style.yellow);
            repl_glue.steerEchoUnlocked("↳ force › interrupting…");
            repl_glue.steerEchoUnlocked(style.reset);
            repl_glue.steerEchoUnlocked("\n");
        }
    }
    main_mod.g_steer_echoed = false;
    main_mod.g_steer_visible.store(false, .release);
    return forced;
}
