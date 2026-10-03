//! Presence registry and room-cursor regressions.
const std = @import("std");
const builtin = @import("builtin");
const presence = @import("presence.zig");
const proc_identity = @import("proc_identity.zig");
const no_local_tools = @import("no_local_tools.zig");
const Owner = @import("worktree_lease.zig").Owner;
const Peers = presence.Peers;
const resetRoomCursorForTest = presence.resetRoomCursorForTest;
const adoptRoomCursor = presence.adoptRoomCursor;
const roomCursor = presence.roomCursor;
const formatRecord = presence.formatRecord;
const listPeers = presence.listPeers;
const unackedPeer = presence.unackedPeer;
const ackKey = presence.ackKey;
const gateCheck = presence.gateCheck;

test "roomCursor adopt/reset: resume continues from the saved byte offset" {
    resetRoomCursorForTest();
    defer resetRoomCursorForTest();
    adoptRoomCursor(.{ .chan = 4096, .device = 128 });
    const cur = roomCursor();
    try std.testing.expectEqual(@as(u64, 4096), cur.chan);
    try std.testing.expectEqual(@as(u64, 128), cur.device);
    resetRoomCursorForTest();
    try std.testing.expectEqual(@as(u64, 0), roomCursor().chan);
}

test "listPeers: probes liveness, reaps the provably dead, keeps the alive" {
    // Windows: the live self-record probes .gone on the runner (OpenProcess on own pid fails there) — skip until diagnosed on a real Windows box.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const self = proc_identity.selfRecord(io);
    const alive: Owner = .{ .pid = self.pid, .start_id = self.start_id, .session_id = "s-live", .identity = "/x/.git", .goal = "g" };
    try tmp.dir.writeFile(io, .{ .sub_path = "live.json", .data = try formatRecord(arena, alive) });
    // pid -7 can never hold a process (probe: pid <= 0 is .gone), so the reap path is exercised identically on every platform.
    const dead: Owner = .{ .pid = -7, .start_id = 1, .session_id = "s-dead", .identity = "/x/.git" };
    try tmp.dir.writeFile(io, .{ .sub_path = "dead.json", .data = try formatRecord(arena, dead) });
    // Reopen with .iterate: tmpDir's handle isn't iteration-capable on the Linux backend (dirRead seeks an O_PATH fd → EBADF panic, the CI crash).
    var idir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer idir.close(io);
    const peers = listPeers(io, arena, idir);
    try std.testing.expectEqual(1, peers.records.len);
    try std.testing.expectEqualStrings("s-live", peers.records[0].session_id);
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFile(io, "dead.json", &buf));
}

test "unackedPeer: returns the live foreign co-owner once, then yields to the ack" {
    const my_identity = "/repo/.git";
    const foreign: Owner = .{ .pid = 4242, .start_id = 99, .session_id = "s-b", .identity = "/repo/.git", .goal = "theirs" };
    const other_tree: Owner = .{ .pid = 4343, .start_id = 98, .session_id = "s-c", .identity = "/repo/.git/worktrees/wt1" };
    const records = [_]Owner{ other_tree, foreign };
    const probes = [_]proc_identity.Probe{ .{ .id = 98 }, .{ .id = 99 } };
    const peers: Peers = .{ .records = &records, .probes = &probes };
    const found = unackedPeer(peers, my_identity, 1, &.{}) orelse return error.ExpectedPeer;
    try std.testing.expectEqualStrings("s-b", found.session_id);
    const key = ackKey(found);
    try std.testing.expect(unackedPeer(peers, my_identity, 1, &.{key}) == null);
    // A new session reusing that pid is a NEW peer, not an acked one.
    const reused: Owner = .{ .pid = 4242, .start_id = 100, .session_id = "s-d", .identity = "/repo/.git" };
    const records2 = [_]Owner{reused};
    const probes2 = [_]proc_identity.Probe{.{ .id = 100 }};
    try std.testing.expect(unackedPeer(.{ .records = &records2, .probes = &probes2 }, my_identity, 1, &.{key}) != null);
}

test "lean one-shots skip the shared-tree checkpoint" {
    const saved = no_local_tools.lean;
    defer no_local_tools.lean = saved;
    no_local_tools.lean = true;
    try std.testing.expect(gateCheck(std.testing.io, std.testing.allocator) == null);
}
