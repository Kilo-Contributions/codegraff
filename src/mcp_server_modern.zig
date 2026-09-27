//! `graff mcp serve` as a 2026-07-28 (stateless) server, beside the legacy
//! `initialize` path in mcp_server.zig.
//!
//! A request is modern when its `params._meta` names a protocol version. It
//! needs no handshake: the version and client capabilities ride every
//! request. Results carry `resultType`, and the cacheable ones (`server/
//! discover`, the list methods, `resources/read`) carry `ttlMs` and
//! `cacheScope`. An unknown version gets -32022 with `supported` and
//! `requested`, which is also what tells a dual-era client this server is
//! modern at all.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp_protocol = @import("mcp_protocol.zig");

pub const version = mcp_protocol.modern_protocol;
const version_key = "io.modelcontextprotocol/protocolVersion";
const capabilities_key = "io.modelcontextprotocol/clientCapabilities";

/// Every revision this server answers: the modern one, then the legacy
/// `initialize` revisions in preference order.
pub const supported_versions = [_][]const u8{ version, "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" };

/// The catalog and the task-result view only change with the binary, and
/// neither holds user data.
pub const ttl_ms: u64 = 5 * 60 * 1000;

pub const unsupported_code: i32 = -32022;
pub const header_mismatch_code: i32 = -32020;

fn meta(params: Value) ?std.json.ObjectMap {
    if (params != .object) return null;
    const m = params.object.get("_meta") orelse return null;
    return if (m == .object) m.object else null;
}

/// The protocol version a modern request names, or null for a legacy one.
pub fn requestedVersion(params: Value) ?[]const u8 {
    const m = meta(params) orelse return null;
    const v = m.get(version_key) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn isSupported(requested: []const u8) bool {
    return std.mem.eql(u8, requested, version);
}

/// `{capabilities: <clientCapabilities>}` — the shape mcp_server_app.supported
/// reads from a legacy `initialize`, so both eras share one check.
pub fn capabilityParams(a: Allocator, params: Value) !Value {
    var wrapped: std.json.ObjectMap = .empty;
    if (meta(params)) |m| if (m.get(capabilities_key)) |caps| try wrapped.put(a, "capabilities", caps);
    return .{ .object = wrapped };
}

/// `result` with the modern envelope fields added.
pub fn envelope(a: Allocator, result: anytype, cacheable: bool) !Value {
    const text = try std.json.Stringify.valueAlloc(a, result, .{});
    var value = try std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
    if (value != .object) return error.BadResult;
    try value.object.put(a, "resultType", .{ .string = "complete" });
    if (cacheable) {
        try value.object.put(a, "ttlMs", .{ .integer = ttl_ms });
        try value.object.put(a, "cacheScope", .{ .string = "public" });
    }
    return value;
}

pub fn unsupported(out: *Io.Writer, id: Value, requested: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = out };
    try json.write(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{
        .code = unsupported_code,
        .message = "Unsupported protocol version",
        .data = .{ .supported = supported_versions, .requested = requested },
    } });
    try out.writeByte('\n');
}

/// Why a modern Streamable HTTP request's headers disagree with its body, or
/// null when they agree. `protocol_header`, `method_header` and `name_header`
/// are the raw header values (null when absent).
pub fn headerMismatch(a: Allocator, body: Value, protocol_header: ?[]const u8, method_header: ?[]const u8, name_header: ?[]const u8) !?[]const u8 {
    const params = if (body == .object) body.object.get("params") orelse Value.null else Value.null;
    const requested = requestedVersion(params) orelse return null;
    if (!std.mem.eql(u8, protocol_header orelse "", requested)) return "MCP-Protocol-Version header does not match _meta protocolVersion";
    const method = if (body == .object) body.object.get("method") orelse Value.null else Value.null;
    if (method != .string or !std.mem.eql(u8, method_header orelse "", method.string)) return "Mcp-Method header does not match the request method";
    const name_field: ?[]const u8 = if (std.mem.eql(u8, method.string, "tools/call") or std.mem.eql(u8, method.string, "prompts/get"))
        "name"
    else if (std.mem.eql(u8, method.string, "resources/read")) "uri" else null;
    const field = name_field orelse return null;
    const v = if (params == .object) params.object.get(field) orelse Value.null else Value.null;
    if (v != .string) return null; // the handler reports the missing argument
    const expected = try mcp_protocol.headerValue(a, v.string);
    if (!std.mem.eql(u8, name_header orelse "", expected)) return "Mcp-Name header does not match the request";
    return null;
}

pub fn mismatch(out: *Io.Writer, id: Value, why: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = out };
    try json.write(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = header_mismatch_code, .message = why } });
    try out.writeByte('\n');
}

test {
    _ = @import("mcp_server_modern_tests.zig");
}
