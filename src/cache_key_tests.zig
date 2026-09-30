//! Prompt-cache partition keys (ADR 0028 / 0069 / 0223), moved off
//! http_headers.zig for the 600-line cap: project and role-lane boundaries,
//! and the ChatGPT-account partition for codex.

const std = @import("std");
const h = @import("http_headers.zig");
const cache_affinity = @import("cache_affinity.zig");
const Provider = @import("provider.zig").Provider;

const openai: Provider = .{ .id = "openai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "m", .context = 1 };
const xai: Provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "m", .context = 1 };

fn codexFor(account: []const u8) Provider {
    return .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "m", .context = 1, .account = account };
}

test "project and prefix cache keys preserve conversation and sharing boundaries" {
    var fake: usize = 0;
    var sibling_fake: usize = 1;
    const agent: *const anyopaque = @ptrCast(&fake);
    const sibling: *const anyopaque = @ptrCast(&sibling_fake);
    var buf: [96]u8 = undefined;
    const a = h.projectCacheKey(std.testing.io, "main", agent, &buf);
    try std.testing.expectEqual(@as(usize, 36), a.len);
    // Not the version nibble: the project id is process state that session
    // tests restore; the mint path has its own test in http_headers.zig.
    var buf2: [96]u8 = undefined;
    const b = h.projectCacheKey(std.testing.io, "main", agent, &buf2);
    try std.testing.expectEqualStrings(a, b); // durable: no per-process randomness
    try std.testing.expectEqualStrings(a, h.projectRootId(std.testing.io));
    try std.testing.expect(!std.mem.eql(u8, a, h.sessionId(std.testing.io)));

    // Live keys (promptCacheKey) share a role lane — xAI cache is per-server
    // and prefix-matched; a unique suffix per sibling is a forced miss.
    var buf3: [96]u8 = undefined;
    var buf4: [96]u8 = undefined;
    const sub = h.promptCacheKey(std.testing.io, "sub", agent, &buf3);
    const sibling_sub = h.promptCacheKey(std.testing.io, "sub", sibling, &buf4);
    try std.testing.expectEqualStrings(sub, sibling_sub);
    try std.testing.expect(!std.mem.eql(u8, sub, a));

    var btw_buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(a, h.projectCacheKey(std.testing.io, "btw", sibling, &btw_buf));

    // OpenAI/Codex prefix affinity is stable for a workflow role, but spreads
    // different roles over four lanes to stay below the per-key traffic guide.
    var pbuf1: [96]u8 = undefined;
    var pbuf2: [96]u8 = undefined;
    const prefix1 = h.promptPrefixCacheKey(std.testing.io, "implement", &pbuf1);
    const prefix2 = h.promptPrefixCacheKey(std.testing.io, "implement", &pbuf2);
    try std.testing.expectEqualStrings(prefix1, prefix2);
    try std.testing.expect(std.mem.startsWith(u8, prefix1, a));
    try std.testing.expect(!std.mem.eql(u8, prefix1, a));

    // OpenAI and xAI scouts share a role lane (header and body use this).
    var oai1: [96]u8 = undefined;
    var oai2: [96]u8 = undefined;
    const oai_lane = h.requestCacheKey(std.testing.io, "implement", agent, openai, &oai1);
    try std.testing.expectEqualStrings(oai_lane, h.requestCacheKey(std.testing.io, "implement", sibling, openai, &oai2));
    var xai1: [96]u8 = undefined;
    var xai2: [96]u8 = undefined;
    const xai_lane = h.requestCacheKey(std.testing.io, "implement", agent, xai, &xai1);
    try std.testing.expectEqualStrings(xai_lane, h.requestCacheKey(std.testing.io, "implement", sibling, xai, &xai2));
    try std.testing.expectEqualStrings(oai_lane, xai_lane);

    // rlm's subagent("task") defaults description to "subagent" — siblings
    // share one prefix lane on every provider, including xAI.
    var rlm1: [96]u8 = undefined;
    var rlm2: [96]u8 = undefined;
    const rlm_lane = h.requestCacheKey(std.testing.io, "subagent", agent, xai, &rlm1);
    try std.testing.expectEqualStrings(rlm_lane, h.requestCacheKey(std.testing.io, "subagent", sibling, xai, &rlm2));
    try std.testing.expect(std.mem.indexOf(u8, rlm_lane, "-child-") != null);
}

test "codex with an account id partitions by account, not by repo" {
    var fake: usize = 0;
    var sibling_fake: usize = 1;
    const agent: *const anyopaque = @ptrCast(&fake);
    const sibling: *const anyopaque = @ptrCast(&sibling_fake);
    const io = std.testing.io;
    var want_buf: [36]u8 = undefined;
    const want = cache_affinity.accountRootId("codex", "acct-a", &want_buf).?;
    // The root key is the account's, whatever repo this process runs in.
    var r1: [96]u8 = undefined;
    const root = h.requestCacheKey(io, "main", agent, codexFor("acct-a"), &r1);
    try std.testing.expectEqualStrings(want, root);
    try std.testing.expect(!std.mem.eql(u8, root, h.projectRootId(io)));
    try std.testing.expectEqual(@as(u8, '5'), root[14]); // still a name-derived UUID
    // /btw shares it; children take a role lane on the account base.
    var b1: [96]u8 = undefined;
    try std.testing.expectEqualStrings(root, h.requestCacheKey(io, "btw", sibling, codexFor("acct-a"), &b1));
    var c1: [96]u8 = undefined;
    var c2: [96]u8 = undefined;
    const lane = h.requestCacheKey(io, "implement", agent, codexFor("acct-a"), &c1);
    try std.testing.expectEqualStrings(lane, h.requestCacheKey(io, "implement", sibling, codexFor("acct-a"), &c2));
    try std.testing.expect(std.mem.startsWith(u8, lane, root) and std.mem.indexOf(u8, lane, "-child-") != null);
    // Another account is another partition.
    var o1: [96]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, root, h.requestCacheKey(io, "main", agent, codexFor("acct-b"), &o1)));
    // No account id (or another provider): the project key, as before.
    var n1: [96]u8 = undefined;
    var p1: [96]u8 = undefined;
    try std.testing.expectEqualStrings(h.promptCacheKey(io, "main", agent, &p1), h.requestCacheKey(io, "main", agent, codexFor(""), &n1));
    var x1: [96]u8 = undefined;
    var xp: Provider = xai;
    xp.account = "acct-a";
    try std.testing.expectEqualStrings(h.promptCacheKey(io, "main", agent, &p1), h.requestCacheKey(io, "main", agent, xp, &x1));
}

test "codex account key: the session_id header carries the same value" {
    var fake: usize = 0;
    const agent: *const anyopaque = @ptrCast(&fake);
    var kbuf: [96]u8 = undefined;
    const key = h.requestCacheKey(std.testing.io, "main", agent, codexFor("acct-a"), &kbuf);
    var hbuf: [12]std.http.Header = undefined;
    const headers = h.providerHeadersWithConv(std.testing.io, codexFor("acct-a"), "Bearer k", &hbuf, key);
    for (headers) |hd| {
        if (std.mem.eql(u8, hd.name, "session_id")) return std.testing.expectEqualStrings(key, hd.value);
    }
    return error.SessionIdHeaderMissing;
}
