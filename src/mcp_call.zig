//! MCP invocation and recovery, separated from registry lifecycle.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Registry = @import("mcp.zig").Registry;
const mcp_rpc = @import("mcp_rpc.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_elicitation = @import("mcp_elicitation.zig");
const initializeServer = mcp_rpc.initializeServer;
const request = mcp_rpc.request;
const renderContent = @import("mcp_content.zig").renderContent;
const Server = mcp_rpc.Server;

/// One server/tool for MRTR retries (mcp_mrtr.resolve).
const McpCall = struct {
    server: *Server,
    name: []const u8,
    fn send(self: McpCall, a: Allocator, params: []const u8) anyerror!Value {
        return request(self.server, a, params, "tools/call", self.name);
    }
};

pub const CallResult = struct { text: []u8, is_error: bool };

/// The registry lock is held throughout. Never replay a possibly executed call.
pub fn call(reg: *Registry, out_alloc: Allocator, qualified: []const u8, input: Value, context: ?@import("mcp_turn_context.zig").Snapshot) !CallResult {
    return invoke(reg, out_alloc, qualified, input, context) catch |err| switch (err) {
        error.McpClosed, error.ReadFailed, error.WriteFailed, error.BrokenPipe, error.ConnectionResetByPeer => blk: {
            try withdrawServer(reg, qualified);
            break :blk .{
                .text = try std.fmt.allocPrint(out_alloc, "MCP service connection closed or failed ({s}). Its tools have been withdrawn from the catalog. The tool may not have completed; it was not retried automatically. Inspect /mcp, restart the service and this session, then reload its tool schemas.", .{@errorName(err)}),
                .is_error = true,
            };
        },
        else => return err,
    };
}

fn withdrawServer(reg: *Registry, qualified: []const u8) !void {
    const server_index = for (reg.tools) |tool| {
        if (std.mem.eql(u8, tool.qualified_name, qualified)) break tool.server_index;
    } else return;
    var available: std.ArrayList(@import("mcp.zig").Tool) = .empty;
    for (reg.tools) |tool| if (tool.server_index != server_index) try available.append(reg.arena(), tool);
    // Replace the slice instead of mutating snapshots held by in-flight callers.
    reg.tools = try available.toOwnedSlice(reg.arena());
    reg.catalog_dirty.store(true, .release);
}

fn invoke(reg: *Registry, out_alloc: Allocator, qualified: []const u8, input: Value, context: ?@import("mcp_turn_context.zig").Snapshot) !CallResult {
    const tool = for (reg.tools) |t| {
        if (std.mem.eql(u8, t.qualified_name, qualified)) break t;
    } else {
        reg.catalog_dirty.store(true, .release);
        return .{ .text = try out_alloc.dupe(u8, "MCP tool is not registered in the current connection. Its loaded schema may be stale. The next catalog will reflect the current registration. Inspect /mcp, restart the session to reconnect the configured service, then reload its schema before retrying."), .is_error = true };
    };

    const server = reg.servers[tool.server_index];
    const turn_ctx = @import("mcp_turn_context.zig").effective(context, reg.io, server.name);
    const params = try @import("mcp_turn_context.zig").params(reg.gpa, server.name, tool.original_name, input, turn_ctx);
    defer reg.gpa.free(params);

    // Tool responses can be large and numerous; keep them out of the
    // session arena. Only the returned text is copied to `out_alloc`.
    var response_arena_state = std.heap.ArenaAllocator.init(reg.gpa);
    defer response_arena_state.deinit();
    const response_alloc = response_arena_state.allocator();
    if (server.transport == .dormant) @import("mcp_lazy.zig").wake(reg, server) catch |err|
        return .{ .text = try std.fmt.allocPrint(out_alloc, "MCP server {s} failed to start: {t}", .{ server.name, err }), .is_error = true };
    if (!server.initialized) try initializeServer(server, response_alloc, reg.arena(), null);
    server.elicit_source = params;
    defer server.elicit_source = "";
    const first_resp = request(server, response_alloc, params, "tools/call", tool.original_name) catch |err| switch (err) {
        // Streamable HTTP servers use 404 to expire a session. Re-run the
        // MCP handshake once, then retry the call without the stale ID.
        // A modern-era server never carries a session id in the first
        // place (mcp_http never sends/stores one for a modern request),
        // so this cannot structurally fire for one — the explicit guard
        // is defense-in-depth against a future refactor resurrecting a
        // re-handshake loop against a server that has no `initialize`.
        error.McpSessionExpired => retry: {
            if (server.era != .legacy) return err;
            try initializeServer(server, response_alloc, reg.arena(), null);
            break :retry try request(server, response_alloc, params, "tools/call", tool.original_name);
        },
        else => return err,
    };

    // Resolve bounded MRTR input requests before interpreting the tool result.
    const call_ctx: McpCall = .{ .server = server, .name = tool.original_name };
    const resp = try @import("mcp_mrtr.zig").resolve(response_alloc, params, first_resp, call_ctx, McpCall.send);
    if (resp != .object) return error.BadMcpResponse;

    if (resp.object.get("error")) |e| {
        // Protocol-level failure (unknown tool, invalid args, server
        // crash) — distinct from a tool that ran and *returned* an error
        // (isError below). Keep the JSON-RPC code: models retry better
        // when they can tell -32602 bad-params from a tool-side failure.
        const msg = if (e == .object) blk: {
            const m = e.object.get("message") orelse break :blk "MCP error";
            break :blk if (m == .string) m.string else "MCP error";
        } else "MCP error";
        const code: i64 = if (e == .object) blk: {
            const c = e.object.get("code") orelse break :blk 0;
            break :blk if (c == .integer) c.integer else 0;
        } else 0;
        if (mcp_elicitation.looksUnavailable(msg))
            return .{ .text = try out_alloc.dupe(u8, mcp_elicitation.fallback), .is_error = true };
        const text = if (code != 0)
            try std.fmt.allocPrint(out_alloc, "MCP error {d}: {s}", .{ code, msg })
        else
            try out_alloc.dupe(u8, msg);
        return .{ .text = text, .is_error = true };
    }
    // A well-formed JSON-RPC reply has `result` xor `error`; `error` was
    // handled above. Guard a malformed server that sends neither (or a
    // non-object result) instead of force-unwrapping into a panic.
    const result_val = resp.object.get("result") orelse
        return .{ .text = try out_alloc.dupe(u8, "MCP response had neither result nor error"), .is_error = true };
    if (result_val != .object)
        return .{ .text = try out_alloc.dupe(u8, "MCP response result was not an object"), .is_error = true };
    const result = result_val.object;
    // resultType absent MUST read as "complete". input_required was
    // resolved above; any other type is surfaced, never returned as "".
    if (!mcp_protocol.resultIsComplete(result))
        return .{ .text = try out_alloc.dupe(u8, "MCP server returned an unsupported resultType"), .is_error = true };
    const is_error = if (result.get("isError")) |v| (v == .bool and v.bool) else false;

    var ow: Io.Writer.Allocating = .init(out_alloc);
    errdefer ow.deinit();
    if (tool.ui_resource_uri) |uri| {
        const path = @import("mcp_apps.zig").snapshot(reg.io, response_alloc, reg.home, server, uri, input, result_val) catch null;
        if (path) |p| {
            reg.last_app_path = try reg.arena().dupe(u8, p);
            try ow.writer.print("[MCP app]({s}) — saved interactive result; /mcp apps opens it in a browser.\n", .{p});
        } else try ow.writer.writeAll("[MCP app view unavailable; ordinary tool output follows.]\n");
    }
    const prefix_len = ow.writer.buffered().len;
    if (result.get("content")) |content| try renderContent(&ow.writer, content, .{
        .arena = reg.arena(),
        .slot = &reg.pending_image,
        .label = qualified,
        .supports_vision = reg.vision_capable,
    });
    // 2025-06-18+ structured tool output: if the server sent only
    // structuredContent (no text blocks), surface it instead of "".
    if (ow.writer.buffered().len == prefix_len) {
        if (result.get("structuredContent")) |sc| {
            var sw: std.json.Stringify = .{ .writer = &ow.writer };
            try sw.write(sc);
        }
    }
    const text = try ow.toOwnedSlice();
    if (mcp_elicitation.looksUnavailable(text)) {
        out_alloc.free(text);
        return .{ .text = try out_alloc.dupe(u8, mcp_elicitation.fallback), .is_error = true };
    }
    return .{ .text = text, .is_error = is_error };
}
