//! WebSocket handshake headers per provider. The WS path cannot reuse
//! providerHeaders (std.http.Header vs ws.Header, and codex's socket adds a
//! websockets beta + User-Agent), so the selection lives in one place.

const std = @import("std");
const Io = std.Io;
const ws = @import("ws.zig");
const http_headers = @import("http_headers.zig");
const Provider = @import("provider.zig").Provider;

/// Authorization plus the provider's affinity/identity headers. Codex sends
/// the full ChatGPT-backend set; other session_id routes (chatgpt-new) get
/// Authorization + session_id only — the Platform endpoint rejects backend
/// identity. xAI sends its grok-build affinity pair.
pub fn handshakeHeaders(io: Io, provider: Provider, bearer: []const u8, conv: []const u8, hdrs: *[7]ws.Header) []const ws.Header {
    var hn: usize = 1;
    hdrs[0] = .{ .name = "Authorization", .value = bearer };
    if (std.mem.eql(u8, provider.id, "codex")) {
        hdrs[1] = .{ .name = "session_id", .value = conv };
        hdrs[2] = .{ .name = "chatgpt-account-id", .value = provider.account };
        hdrs[3] = .{ .name = "OpenAI-Beta", .value = "responses_websockets=2026-02-06" };
        hdrs[4] = .{ .name = "originator", .value = "codex_cli_rs" };
        hdrs[5] = .{ .name = "User-Agent", .value = "codex_cli_rs/0.1 (graff)" };
        hn = 6;
    } else if (http_headers.wantsSessionIdHeader(provider.id)) {
        hdrs[1] = .{ .name = "session_id", .value = conv };
        hn = 2;
    } else if (http_headers.wantsGrokConvId(provider.id)) {
        hdrs[1] = .{ .name = "x-grok-session-id", .value = http_headers.projectRootId(io) };
        hdrs[2] = .{ .name = "x-grok-conv-id", .value = conv };
        hn = 3;
    }
    return hdrs[0..hn];
}

test "chatgpt-new WS handshake sends session_id only; codex keeps the full set" {
    const io = std.testing.io;
    var hdrs: [7]ws.Header = undefined;
    const chatgpt: Provider = .{ .id = "chatgpt-new", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-6.1-sol", .context = 272_000 };
    const h = handshakeHeaders(io, chatgpt, "Bearer k", "conv-1", &hdrs);
    try std.testing.expectEqual(@as(usize, 2), h.len);
    try std.testing.expectEqualStrings("Authorization", h[0].name);
    try std.testing.expectEqualStrings("session_id", h[1].name);
    try std.testing.expectEqualStrings("conv-1", h[1].value);

    const codex: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-5.6", .context = 272_000, .account = "acct" };
    const c = handshakeHeaders(io, codex, "Bearer k", "conv-1", &hdrs);
    try std.testing.expectEqual(@as(usize, 6), c.len);
    const names = [_][]const u8{ "Authorization", "session_id", "chatgpt-account-id", "OpenAI-Beta", "originator", "User-Agent" };
    for (names, c) |want, got| try std.testing.expectEqualStrings(want, got.name);
    try std.testing.expectEqualStrings("conv-1", c[1].value);
    try std.testing.expectEqualStrings("acct", c[2].value);
}

test "xAI WS handshake keeps the grok pair; openai sends Authorization only" {
    const io = std.testing.io;
    var hdrs: [7]ws.Header = undefined;
    const xai: Provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.6", .context = 500_000 };
    const x = handshakeHeaders(io, xai, "Bearer k", "conv-1", &hdrs);
    try std.testing.expectEqual(@as(usize, 3), x.len);
    try std.testing.expectEqualStrings("x-grok-session-id", x[1].name);
    try std.testing.expectEqualStrings(http_headers.projectRootId(io), x[1].value);
    try std.testing.expectEqualStrings("x-grok-conv-id", x[2].name);
    try std.testing.expectEqualStrings("conv-1", x[2].value);

    const openai: Provider = .{ .id = "openai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-5.6", .context = 272_000 };
    const o = handshakeHeaders(io, openai, "Bearer k", "conv-1", &hdrs);
    try std.testing.expectEqual(@as(usize, 1), o.len);
    try std.testing.expectEqualStrings("Authorization", o[0].name);
}
