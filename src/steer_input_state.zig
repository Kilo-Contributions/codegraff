//! Framing state shared by the line-REPL stdin scanner and its turn-boundary
//! reset. The scanner lock serializes terminal reads with reset; steerLock
//! separately protects the mutable draft/queue and stdout row.
const std = @import("std");

pub const State = struct {
    mode: Mode = .normal,
    csi: [64]u8 = undefined,
    csi_len: usize = 0,
    in_paste: bool = false,
    paste_bytes: usize = 0,
    paste_lines: usize = 0,
    pasted_cr: bool = false,
    entered_cr: bool = false,

    pub const Mode = enum { normal, esc, csi, ss3, osc, osc_esc };
};

pub var scan: State = .{};
var scan_lock: std.atomic.Value(bool) = .init(false);

pub fn lock() void {
    while (scan_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

pub fn unlock() void {
    scan_lock.store(false, .release);
}
