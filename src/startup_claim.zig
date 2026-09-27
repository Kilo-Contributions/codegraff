//! A per-checkout startup claim for auto-isolation (#1200).
//!
//! A session writes its presence record only after boot, so two sessions
//! started together both read the checkout as unclaimed and both stay on the
//! primary working tree. Before deciding, an eligible session takes this claim
//! with an exclusive create, which is atomic across processes. A fresh claim
//! held by another live process means the checkout is contended and this
//! session isolates. After `window_ms` the presence registry is authoritative
//! again, so a session that later moved off the checkout does not keep forcing
//! isolation, and nothing needs to release the claim.
//!
//! Residual race: two sessions reclaiming the same stale claim in the same
//! instant can both win. That needs a dead owner and a simultaneous start.

const std = @import("std");
const Io = std.Io;
const proc_identity = @import("proc_identity.zig");

pub const window_ms: i64 = 60_000;

const Claim = struct { owner: proc_identity.Record, ms: i64 };

fn parse(text: []const u8) ?Claim {
    const owner = proc_identity.parseRecord(text) orelse return null;
    const at = std.mem.indexOf(u8, text, " ms=") orelse return null;
    const rest = text[at + 4 ..];
    const end = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
    return .{ .owner = owner, .ms = std.fmt.parseInt(i64, rest[0..end], 10) catch return null };
}

fn take(io: Io, dir: Io.Dir, name: []const u8, now_ms: i64) bool {
    const me = proc_identity.selfRecord(io);
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "graff-owner 1 pid={d} start={d} ms={d}\n", .{ me.pid, me.start_id, now_ms }) catch return false;
    dir.writeFile(io, .{ .sub_path = name, .data = line, .flags = .{ .exclusive = true } }) catch return false;
    return true;
}

fn liveOther(io: Io, dir: Io.Dir, name: []const u8, now_ms: i64) ?bool {
    var buf: [128]u8 = undefined;
    const text = dir.readFile(io, name, &buf) catch return null;
    const c = parse(text) orelse return false; // unparsable: not an owner
    if (c.owner.pid == proc_identity.selfPid()) return false;
    return now_ms - c.ms < window_ms and proc_identity.stateOf(io, c.owner) == .held;
}

/// True when another live session took this checkout's startup claim within
/// the window. Otherwise the claim is now ours and this returns false.
pub fn heldByOther(io: Io, dir: Io.Dir, name: []const u8, now_ms: i64) bool {
    for (0..2) |_| {
        if (take(io, dir, name, now_ms)) return false;
        const other = liveOther(io, dir, name, now_ms) orelse continue; // vanished: retry
        if (other) return true;
        dir.deleteFile(io, name) catch {}; // stale or our own leftover: retake
    }
    return liveOther(io, dir, name, now_ms) orelse false;
}

/// The claim's file name for one checkout identity.
pub fn fileName(buf: *[48]u8, identity: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "startup-{x:0>16}.claim", .{std.hash.Wyhash.hash(0x1200, identity)}) catch unreachable;
}

test "the first session takes the claim; a fresh live claim is contended; a stale one is retaken" {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var nbuf: [48]u8 = undefined;
    const name = fileName(&nbuf, "/repo/.git");
    const now: i64 = 1_000_000;
    try std.testing.expect(!heldByOther(io, tmp.dir, name, now));
    // Our own claim never contends with us.
    try std.testing.expect(!heldByOther(io, tmp.dir, name, now + 10));

    // pid 1 is always alive: a fresh claim it holds is contention.
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "graff-owner 1 pid=1 start=0 ms=1000000\n" });
    try std.testing.expect(heldByOther(io, tmp.dir, name, now + 5_000));
    // Past the window the registry is authoritative again; the claim is retaken.
    try std.testing.expect(!heldByOther(io, tmp.dir, name, now + window_ms + 1));
    var buf: [128]u8 = undefined;
    const mine = parse(try tmp.dir.readFile(io, name, &buf)).?;
    try std.testing.expectEqual(proc_identity.selfPid(), mine.owner.pid);
}
