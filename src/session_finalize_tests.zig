//! The last session save runs inside `finalizeSession`, after the process has
//! begun releasing its globals. Whatever that save serializes must still be
//! alive when it runs (#1193).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");

test "#1193 the final save records a switched workspace before releasing it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const writer = @import("session_writer.zig");
    const transcript = @import("session_transcript.zig");
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;
    defer _ = std.posix.system.fchdir(orig.handle);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = std.process.currentPath(io, &home_buf) catch return error.SkipZigTest;

    const saved_display = main_mod.g_cwd_display;
    defer main_mod.g_cwd_display = saved_display;
    // What an ACP session/new or session/load into another folder does.
    @import("workspace_display.zig").adopt(gpa, "/work/switched-1193");

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var keys: @import("provider.zig").Keys = .{ .values = @splat("test-key") };
    var root: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = try keys.providerById("anthropic", "sonnet"),
        .messages = (try std.json.parseFromSliceLeaky(std.json.Value, arena, "[{\"role\":\"user\",\"content\":\"final save 1193\"}]", .{})).array,
        .sub = false,
        .label = "root",
        .out = null,
        .home = home_buf[0..home_len],
        .session_name = "finalize-1193",
    };
    var out_buf: [256]u8 = undefined;
    var out: Io.Writer.Discarding = .init(&out_buf);
    try @import("session_run.zig").finalizeSession(gpa, io, arena, &out.writer, &root, true);

    const bytes = try tmp.dir.readFileAlloc(io, ".graff/sessions/finalize-1193.session.json", arena, .limited(1 << 20));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const workspace = parsed.object.get("workspace") orelse return error.MissingWorkspace;
    try std.testing.expectEqualStrings("/work/switched-1193", workspace.string);
    // Released only after the save, and the global no longer aliases it.
    try std.testing.expectEqualStrings(".", main_mod.g_cwd_display);
}
