//! Keep bracketed-paste framing enabled across active line-REPL turns, not
//! just while the idle editor is reading. The modified-key protocol remains
//! editor-scoped; only paste mode persists until the terminal is released.
const std = @import("std");
const Io = std.Io;
const tty = @import("term.zig").tty;
const keys = @import("readline_keys.zig");

var paste_enabled: std.atomic.Value(bool) = .init(false);

pub fn enable(out: *Io.Writer) void {
    out.writeAll(keys.enable_seq) catch return;
    paste_enabled.store(true, .release);
}

pub fn release(out: *Io.Writer) void {
    if (paste_enabled.swap(false, .acq_rel)) {
        out.writeAll("\x1b[?2004l") catch {};
        out.flush() catch {};
    }
    tty.releaseTerminal();
}
