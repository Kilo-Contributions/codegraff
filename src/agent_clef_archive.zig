//! Archive, don't delete: the Clef prune arm's recoverable mode.
//!
//! Without it, a gateway `drop_call` removes the call and its result from
//! history, and a `drop_result` keeps the first few hundred characters and
//! destroys the rest. With `GRAFF_CLEF_ARCHIVE=1`, both become a stub: the
//! call stays (pairing never changes), the result keeps its head, and the full
//! bytes go to the session's artifact dir (#409's spill, same budget and
//! sweep) with the absolute path in the stub, so the next turn can read or
//! grep what was pruned instead of re-running the tool.
//!
//! No durable session (a subagent, an unwired process) or a spent spill
//! budget falls back to the plain truncation marker — never worse than the
//! delete-mode stub.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const tool_spill = @import("tool_spill.zig");

/// GRAFF_CLEF_ARCHIVE=1/true/on arms archive mode (session_settings.applyEnvKnobs).
/// Default off while the experiment runs (evals/clef_exp arm `clefarc`).
pub var g_enabled: bool = false;

/// Replace the output string in `m.<field>` with its first `head_chars` plus a
/// marker. With `session` durable, the full output is archived first and the
/// marker cites its path; otherwise it is the plain truncation marker.
/// Returns bytes freed (0 when the output was already short).
pub fn stubOutput(alloc: Allocator, m: *Value, field: []const u8, head_chars: usize, session: []const u8) usize {
    if (m.* != .object) return 0;
    const obj = &m.object;
    const o = obj.get(field) orelse return 0;
    if (o != .string or o.string.len <= head_chars) return 0;
    const full = o.string;
    const head = utf8Head(full, head_chars);
    const path: ?[]const u8 = if (session.len > 0) tool_spill.spill(alloc, session, full) else null;
    const stub = if (path) |p|
        std.fmt.allocPrint(alloc, "{s}…[archived by compaction: kept first {d} of {d} chars; the FULL output is at {s} — read or grep that file if you need the rest instead of re-running the tool]", .{ head, head.len, full.len, p }) catch return 0
    else
        std.fmt.allocPrint(alloc, "{s}…[truncated: kept first {d} of {d} chars]", .{ head, head.len, full.len }) catch return 0;
    if (stub.len >= full.len) return 0; // a marker longer than what it replaces frees nothing
    obj.put(alloc, field, .{ .string = stub }) catch return 0;
    return full.len - stub.len;
}

/// The longest prefix of `s` within `max` bytes that does not split a UTF-8
/// sequence (a lone continuation byte is invalid JSON-string content upstream).
fn utf8Head(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "stubOutput archives the full output and the stub cites its path" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    tool_spill.resetForTest();
    defer tool_spill.resetForTest();
    tool_spill.enable(.{ .io = io, .dir = tmp.dir, .base_abs = "" });

    const big = try a.alloc(u8, 4096);
    @memset(big, 'x');
    @memcpy(big[3000..][0..9], "NEEDLE254");
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "role", .{ .string = "tool" });
    try obj.put(a, "content", .{ .string = big });
    var m: Value = .{ .object = obj };

    try testing.expect(stubOutput(a, &m, "content", 100, "s1") > 0);
    const stub = m.object.get("content").?.string;
    try testing.expect(std.mem.indexOf(u8, stub, "archived by compaction") != null);
    try testing.expect(std.mem.indexOf(u8, stub, "tool-0.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stub, "NEEDLE254") == null);
    const saved = try tmp.dir.readFileAlloc(io, ".graff/sessions/s1/artifacts/tool-0.txt", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings(big, saved);
}

test "stubOutput without a durable session is the plain truncation" {
    tool_spill.resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var obj: std.json.ObjectMap = .empty;
    const ys = @import("util.zig").repeatBytes("y", 1000);
    try obj.put(a, "output", .{ .string = &ys });
    var m: Value = .{ .object = obj };
    try testing.expect(stubOutput(a, &m, "output", 10, "") > 0);
    const stub = m.object.get("output").?.string;
    try testing.expect(std.mem.indexOf(u8, stub, "truncated: kept first 10 of 1000") != null);
    // Already short: untouched, nothing freed.
    try testing.expectEqual(@as(usize, 0), stubOutput(a, &m, "output", 10_000, ""));
}

test "utf8Head never splits a multi-byte sequence" {
    try testing.expectEqualStrings("a", utf8Head("aé", 2)); // é is 2 bytes at [1..3]
    try testing.expectEqualStrings("aé", utf8Head("aéb", 3));
    try testing.expectEqualStrings("ab", utf8Head("ab", 5));
}
