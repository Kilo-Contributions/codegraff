//! Complete, current MCP tool catalogs.
//!
//! - `tools/list` is paginated: a server may return `nextCursor` and expect
//!   the client to ask again. graff read only the first page, so a large
//!   server's later tools never reached the model. `complete` follows the
//!   cursor (bounded) and merges every page.
//! - A server can change its tools mid-session and say so with
//!   `notifications/tools/list_changed` (mcp_notify marks it stale). A
//!   2026-07-28 stdio server only sends that after `subscriptions/listen`,
//!   which `listen` requests at connect. `refreshStale` re-lists each stale
//!   server before the next model request so the catalog is not frozen at
//!   connect time.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
const mcp_rpc = @import("mcp_rpc.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const Server = mcp_rpc.Server;
const Tool = mcp.Tool;

pub const max_pages = 32;

pub const Listed = struct { result: Value, tools: Value };

fn nextCursor(o: std.json.ObjectMap) ?[]const u8 {
    const c = o.get("nextCursor") orelse return null;
    return if (c == .string and c.string.len > 0) c.string else null;
}

/// `first` is the first `tools/list` result. Follows `nextCursor` and
/// returns one result whose `tools` holds every page. A failed later page
/// ends the listing with what was already read.
pub fn complete(server: *Server, a: Allocator, io: ?Io, first: Value) !Listed {
    if (first != .object) return error.BadMcpResponse;
    const tv = first.object.get("tools") orelse return error.BadMcpResponse;
    if (tv != .array) return error.BadMcpResponse;
    var cursor = nextCursor(first.object) orelse return .{ .result = first, .tools = tv };
    var all = std.json.Array.init(a);
    try all.appendSlice(tv.array.items);
    var pages: usize = 1;
    while (pages < max_pages) : (pages += 1) {
        const params = try std.json.Stringify.valueAlloc(a, .{ .cursor = cursor }, .{});
        const resp = mcp_rpc.handshakeRequest(server, a, io, params, "tools/list") catch break;
        if (resp != .object) break;
        const r = resp.object.get("result") orelse break;
        if (r != .object) break;
        const page = r.object.get("tools") orelse break;
        if (page != .array) break;
        try all.appendSlice(page.array.items);
        const next = nextCursor(r.object) orelse break;
        if (std.mem.eql(u8, next, cursor)) break; // a server repeating itself
        cursor = next;
    }
    var merged = try first.object.clone(a);
    _ = merged.orderedRemove("nextCursor");
    try merged.put(a, "tools", .{ .array = all });
    return .{ .result = .{ .object = merged }, .tools = .{ .array = all } };
}

/// The registry's tool records for one server's `tools` array.
pub fn appendTools(a: Allocator, tools: *std.ArrayList(Tool), server_index: usize, server: *const Server, tools_v: Value) !void {
    for (tools_v.array.items) |t| {
        if (t != .object) continue;
        if (!@import("mcp_apps.zig").modelVisible(t)) continue;
        const name_v = t.object.get("name") orelse continue;
        if (name_v != .string) continue;
        const orig = try a.dupe(u8, name_v.string);
        const qualified = try @import("mcp_names.zig").qualify(a, server.name, orig);
        // Prefer description; fall back to the 2025-06-18+ human-readable
        // title so a metadata-only tool isn't blank to the model.
        const desc = if (t.object.get("description")) |d| (if (d == .string) d.string else "") else if (t.object.get("title")) |ti| (if (ti == .string) ti.string else "") else "";
        var schema = t.object.get("inputSchema") orelse Value{ .object = .empty };
        try mcp_protocol.rewriteOneOf(a, &schema);
        // ...then lower any TOP-LEVEL combinator: Anthropic rejects the
        // whole request over one, so a single server advertising it would
        // break every turn (codedbpro's `replace`, "path or paths").
        try mcp_protocol.flattenTopLevel(a, &schema);
        try tools.append(a, .{
            .server_index = server_index,
            .server_name = server.name,
            .original_name = orig,
            .qualified_name = qualified,
            .description = try a.dupe(u8, desc),
            .input_schema = schema,
            .ui_resource_uri = if (@import("mcp_apps.zig").resourceUri(t)) |uri| try a.dupe(u8, uri) else null,
        });
    }
}

/// Ask a 2026-07-28 stdio server for `notifications/tools/list_changed`.
/// Fire and forget: the acknowledgement and later notifications are read
/// (and observed) by the next request's wait, and the id never matches a
/// real request. A server without subscriptions answers with an error that
/// is skipped the same way.
pub fn listen(server: *Server, a: Allocator) void {
    if (server.era != .modern or server.transport != .stdio) return;
    const id = server.next_id;
    server.next_id += 1;
    const line = mcp_protocol.buildRequest(a, id, "subscriptions/listen", "{\"notifications\":{\"toolsListChanged\":true}}", true) catch return;
    mcp_stdio.writeRequest(&server.transport.stdio.stdin_writer.interface, line) catch {};
}

/// Before each model request: merge finished deferred handshakes, then
/// re-list servers whose tools changed. True when the catalog must rebuild.
pub fn beforeRequest(reg: *mcp.Registry) bool {
    const added = @import("mcp_watch.zig").poll(reg); // servers added mid-session
    const joined = @import("mcp_boot.zig").joinBeforeRequest(reg) or added;
    const refreshed = refreshStale(reg);
    return joined or refreshed;
}

/// Re-list every server that announced a tool change. True when the
/// registry's tools changed, so the caller rebuilds the model's catalog.
pub fn refreshStale(reg: *mcp.Registry) bool {
    reg.mutex.lockUncancelable(reg.io);
    defer reg.mutex.unlock(reg.io);
    var changed = false;
    for (reg.servers, 0..) |server, i| {
        if (!server.notes.tools_stale.swap(false, .acq_rel)) continue;
        const a = reg.arena();
        const resp = mcp_rpc.handshakeRequest(server, a, reg.io, "{}", "tools/list") catch continue;
        if (resp != .object) continue;
        const first = resp.object.get("result") orelse continue;
        const listed = complete(server, a, reg.io, first) catch continue;
        var tools: std.ArrayList(Tool) = .empty;
        for (reg.tools) |t| if (t.server_index != i) tools.append(a, t) catch return changed;
        appendTools(a, &tools, i, server, listed.tools) catch continue;
        reg.tools = tools.items;
        changed = true;
    }
    return changed;
}
