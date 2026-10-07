//! ADR 0270 (#1512): a stdio MCP server whose connection closes starts again
//! on its next call instead of leaving the session without its tools.
//!
//! The call that saw the close is never replayed: it may have run. The dead
//! child is reaped and the server goes back to dormant with the launch config
//! it started from, so the next call spawns and handshakes a fresh process
//! exactly as a first use does (mcp_lazy.wake). Its tools stay advertised.
//! A server that keeps closing is withdrawn after `max_restarts`, as before.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Registry = @import("mcp.zig").Registry;
const mcp_stdio = @import("mcp_stdio.zig");

/// Restarts per server per session before its tools are withdrawn.
pub const max_restarts: u8 = 2;

/// After a transport failure on `qualified`'s server: return a stdio server
/// that can be relaunched to dormant and answer with the call's error text.
/// Null when it cannot restart (HTTP, no launch config, budget spent), so the
/// caller withdraws its tools. The registry lock is held by the caller.
pub fn closeForRestart(reg: *Registry, out_alloc: Allocator, qualified: []const u8, reason: []const u8) !?[]u8 {
    const tool = for (reg.tools) |t| {
        if (std.mem.eql(u8, t.qualified_name, qualified)) break t;
    } else return null;
    const server = reg.servers[tool.server_index];
    if (server.transport != .stdio) return null;
    const relaunch = server.transport.stdio.relaunch orelse return null;
    if (relaunch.restarts >= max_restarts) return null;
    mcp_stdio.stopChild(reg.io, &server.transport.stdio.child);
    server.transport = .{ .dormant = .{ .cfg = relaunch.cfg, .restarts = relaunch.restarts + 1 } };
    server.initialized = false;
    return try std.fmt.allocPrint(out_alloc, "MCP service connection closed or failed ({s}). The tool may not have completed; it was not retried automatically. The service starts again on its next call; anything it held (open pages, sessions, caches) is gone.", .{reason});
}

test "#1512: a stdio server that closes mid-call starts again on its next call" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // /bin/sh
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    var reg = Registry.empty(gpa, io);
    defer reg.deinit();
    reg.stdio_probe = false;
    reg.lazy_stdio = false;
    // The first process exits on its first tools/call; the next one answers.
    const script = try std.fmt.allocPrint(reg.arena(),
        \\M='{s}/started'; first=0; [ -e "$M" ] || {{ first=1; : > "$M"; }}
        \\while read -r l; do
        \\  id=$(printf '%s' "$l" | sed -n 's/^{{"jsonrpc":"2.0","id":\([0-9]*\),.*/\1/p')
        \\  [ -z "$id" ] && continue
        \\  case "$l" in
        \\    *'"method":"initialize"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"protocolVersion":"2025-06-18","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"f","version":"1"}}}}}}\n' "$id" ;;
        \\    *'"method":"tools/list"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"tools":[{{"name":"whoami","description":"d","inputSchema":{{"type":"object"}}}}]}}}}\n' "$id" ;;
        \\    *'"method":"tools/call"'*) [ "$first" = 1 ] && exit 0; printf '{{"jsonrpc":"2.0","id":%s,"result":{{"content":[{{"type":"text","text":"fresh"}}]}}}}\n' "$id" ;;
        \\    *) printf '{{"jsonrpc":"2.0","id":%s,"error":{{"code":-32601,"message":"no"}}}}\n' "$id" ;;
        \\  esac
        \\done
    , .{path_buf[0..dir_len]});
    try std.testing.expectEqual(@as(usize, 1), try reg.addServer("fixture", "/bin/sh", &.{ "-c", script }));
    const args: std.json.Value = .{ .object = .empty };

    const closed = try reg.call(gpa, "mcp__fixture__whoami", args);
    defer gpa.free(closed.text);
    try std.testing.expect(closed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, closed.text, "McpClosed") != null);
    try std.testing.expect(std.mem.indexOf(u8, closed.text, "starts again on its next call") != null);
    // Still advertised: nothing was withdrawn and the catalog is unchanged.
    try std.testing.expectEqual(@as(usize, 1), (try reg.snapshotTools(reg.arena())).len);
    try std.testing.expect(!reg.catalog_dirty.load(.acquire));

    const again = try reg.call(gpa, "mcp__fixture__whoami", args);
    defer gpa.free(again.text);
    try std.testing.expect(!again.is_error);
    try std.testing.expectEqualStrings("fresh", again.text);
}
