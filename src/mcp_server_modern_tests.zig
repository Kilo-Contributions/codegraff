//! `graff mcp serve` speaking 2026-07-28 beside the legacy handshake.
const std = @import("std");
const Value = std.json.Value;
const mcp = @import("mcp_server.zig");
const modern = @import("mcp_server_modern.zig");

const meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"probe","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}
;

fn fake(_: ?*anyopaque, _: std.mem.Allocator, task: mcp.Task) !mcp.Result {
    return .{ .text = task.prompt };
}

fn run(a: std.mem.Allocator, input: []const u8) ![]const Value {
    var source = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(a);
    var server: mcp.Server = .{ .execute = fake };
    try mcp.serve(a, &source, &out.writer, &server);
    var replies: std.ArrayList(Value) = .empty;
    var lines = std.mem.tokenizeScalar(u8, out.written(), '\n');
    while (lines.next()) |line| try replies.append(a, try std.json.parseFromSliceLeaky(Value, a, line, .{}));
    return replies.items;
}

fn result(reply: Value) std.json.ObjectMap {
    return reply.object.get("result").?.object;
}

test "a 2026-07-28 client discovers, lists and calls with no initialize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const replies = try run(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{" ++ meta ++ "}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{" ++ meta ++ ",\"name\":\"run_task\",\"arguments\":{\"prompt\":\"hi\"}}}\n");
    try std.testing.expectEqual(@as(usize, 3), replies.len);

    const discover = result(replies[0]);
    try std.testing.expectEqualStrings("2026-07-28", discover.get("supportedVersions").?.array.items[0].string);
    try std.testing.expectEqualStrings("codegraff", discover.get("serverInfo").?.object.get("name").?.string);
    try std.testing.expect(discover.get("capabilities").?.object.get("tools") != null);
    try std.testing.expectEqualStrings("complete", discover.get("resultType").?.string);
    try std.testing.expectEqualStrings("public", discover.get("cacheScope").?.string);
    try std.testing.expect(discover.get("ttlMs").?.integer >= 0);

    const list = result(replies[1]);
    try std.testing.expectEqualStrings("run_task", list.get("tools").?.array.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("complete", list.get("resultType").?.string);
    try std.testing.expect(list.get("ttlMs") != null and list.get("cacheScope") != null);

    const call = result(replies[2]);
    try std.testing.expectEqualStrings("hi", call.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("complete", call.get("resultType").?.string);
    try std.testing.expect(call.get("ttlMs") == null); // a tool call is not cacheable
}

test "an unknown modern version gets -32022 with supported and requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const replies = try run(a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2099-01-01\"}}}\n");
    const err = replies[0].object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32022), err.get("code").?.integer);
    const data = err.get("data").?.object;
    try std.testing.expectEqualStrings("2099-01-01", data.get("requested").?.string);
    try std.testing.expectEqualStrings("2026-07-28", data.get("supported").?.array.items[0].string);
    try std.testing.expectEqual(@as(i64, 7), replies[0].object.get("id").?.integer);
}

test "legacy clients: discover is method-not-found, initialize negotiates 2025-11-25" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No _meta: a dual-era client falls back to initialize on -32601.
    const replies = try run(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}\n");
    try std.testing.expectEqual(@as(i64, -32601), replies[0].object.get("error").?.object.get("code").?.integer);
    try std.testing.expectEqualStrings("2025-11-25", result(replies[1]).get("protocolVersion").?.string);
    const list = result(replies[2]);
    try std.testing.expect(list.get("tools") != null);
    try std.testing.expect(list.get("resultType") == null); // legacy results keep their old shape

    const unknown = try run(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2030-01-01\"}}\n");
    try std.testing.expectEqualStrings("2025-11-25", result(unknown[0]).get("protocolVersion").?.string);
}

test "MCP Apps is negotiated from the modern client capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const replies = try run(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"extensions\":{\"io.modelcontextprotocol/ui\":{\"mimeTypes\":[\"text/html;profile=mcp-app\"]}}}}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}\n");
    const with_ui = result(replies[0]).get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("ui://codegraff/task-result", with_ui.get("_meta").?.object.get("ui").?.object.get("resourceUri").?.string);
    try std.testing.expect(result(replies[1]).get("tools").?.array.items[0].object.get("_meta") == null);
}

test "Streamable HTTP headers must agree with a modern body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try std.json.parseFromSliceLeaky(Value, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{" ++ meta ++ ",\"name\":\"run_task\",\"arguments\":{}}}", .{});
    try std.testing.expect((try modern.headerMismatch(a, call, "2026-07-28", "tools/call", "run_task")) == null);
    try std.testing.expect((try modern.headerMismatch(a, call, null, "tools/call", "run_task")) != null);
    try std.testing.expect((try modern.headerMismatch(a, call, "2025-11-25", "tools/call", "run_task")) != null);
    try std.testing.expect((try modern.headerMismatch(a, call, "2026-07-28", "tools/list", "run_task")) != null);
    try std.testing.expect((try modern.headerMismatch(a, call, "2026-07-28", "tools/call", "other")) != null);
    try std.testing.expect((try modern.headerMismatch(a, call, "2026-07-28", "tools/call", null)) != null);
    const list = try std.json.parseFromSliceLeaky(Value, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}", .{});
    try std.testing.expect((try modern.headerMismatch(a, list, "2026-07-28", "tools/list", null)) == null);
    // A non-ASCII name travels base64-encoded; the encoded form matches.
    const read = try std.json.parseFromSliceLeaky(Value, a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/read\",\"params\":{" ++ meta ++ ",\"uri\":\"ui://café\"}}", .{});
    const encoded = try @import("mcp_protocol.zig").headerValue(a, "ui://café");
    try std.testing.expect((try modern.headerMismatch(a, read, "2026-07-28", "resources/read", encoded)) == null);
    try std.testing.expect((try modern.headerMismatch(a, read, "2026-07-28", "resources/read", "ui://café")) != null);
    // A legacy body has nothing to check.
    const legacy = try std.json.parseFromSliceLeaky(Value, a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\"}", .{});
    try std.testing.expect((try modern.headerMismatch(a, legacy, null, null, null)) == null);
}
