//! Codegraff gateway + Claude = the native Messages wire end to end: headers,
//! body, cache TTL. Split into its own module because the touched files are at
//! the 600-line ceiling.

const std = @import("std");
const Provider = @import("provider.zig").Provider;
const http_headers = @import("http_headers.zig");
const claude = @import("claude_wire.zig");
const responses_body = @import("agent_request_body_responses.zig");

test "codegraff Claude sends bearer + anthropic-version + binding beta, never x-api-key" {
    const io = std.testing.io;
    var buf: [12]std.http.Header = undefined;
    const p: Provider = .{ .id = "codegraff", .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "k", .model = "claude-opus-5-5", .context = 1_000_000 };
    const headers = http_headers.providerHeaders(io, p, "Bearer k", &buf);
    // Then only the gateway's client tags (client_tags.zig), never x-api-key.
    try std.testing.expect(headers.len >= 3);
    for (headers[3..]) |h| try std.testing.expect(std.mem.startsWith(u8, h.name, "X-Codegraff-"));
    for (headers) |h| try std.testing.expect(!std.ascii.eqlIgnoreCase(h.name, "x-api-key"));
    try std.testing.expectEqualStrings("authorization", headers[0].name);
    try std.testing.expectEqualStrings("Bearer k", headers[0].value);
    try std.testing.expectEqualStrings("anthropic-version", headers[1].name);
    try std.testing.expectEqualStrings("anthropic-beta", headers[2].name);
    try std.testing.expectEqualStrings(claude.binding_beta, headers[2].value);
}

test "codegraff Claude writes the identical Messages body the Anthropic API gets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var direct = try responses_body.testAgentFor(a, "anthropic", .anthropic, "claude-opus-5-5");
    var gateway = try responses_body.testAgentFor(a, "codegraff", .anthropic, "claude-opus-5-5");
    const ab = try direct.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ab);
    const gb = try gateway.buildBody(null, false, true, true);
    defer std.testing.allocator.free(gb);
    try std.testing.expectEqualStrings(ab, gb);
    // The Claude-shaped fields the compat layer used to lose are present.
    try std.testing.expect(std.mem.indexOf(u8, gb, "\"max_tokens\":64000") != null);
    try std.testing.expect(std.mem.indexOf(u8, gb, "cache_control") != null);
    try std.testing.expect(std.mem.indexOf(u8, gb, "\"tool_choice\"") == null);
}
