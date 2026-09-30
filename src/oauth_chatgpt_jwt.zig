//! ID-token checks for the ChatGPT plan sign-in (ADR 0221): the RS256
//! signature against OpenAI's published JWKS, then issuer, audience, expiry
//! and nonce. The signature math is std.crypto's PKCS#1 v1.5 verifier; this
//! file only picks the key and reads the claims.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const rsa = std.crypto.Certificate.rsa;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const issuer = "https://auth.openai.com";
pub const jwks_url = issuer ++ "/.well-known/jwks.json";

pub const Claims = struct { sub: []const u8, email: []const u8 = "", exp: i64 };

fn decode(arena: Allocator, part: []const u8) ![]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const buf = try arena.alloc(u8, dec.calcSizeForSlice(part) catch return error.BadIdToken);
    dec.decode(buf, part) catch return error.BadIdToken;
    return buf;
}

fn object(arena: Allocator, bytes: []const u8) !std.json.ObjectMap {
    const v = std.json.parseFromSliceLeaky(Value, arena, bytes, .{ .allocate = .alloc_always }) catch return error.BadIdToken;
    return if (v == .object) v.object else error.BadIdToken;
}

fn str(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn audienceMatches(aud: ?Value, want: []const u8) bool {
    const v = aud orelse return false;
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, want),
        .array => |arr| for (arr.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, want)) break true;
        } else false,
        else => false,
    };
}

/// Verify `token` with one JWK (`n`, `e` base64url) and return its claims
/// after the issuer, audience, expiry and nonce checks. A null `nonce` skips
/// that check: refresh responses carry none.
pub fn verifyWithKey(arena: Allocator, token: []const u8, n_b64: []const u8, e_b64: []const u8, audience: []const u8, nonce: ?[]const u8, now_s: i64) !Claims {
    const dot1 = std.mem.indexOfScalar(u8, token, '.') orelse return error.BadIdToken;
    const dot2 = std.mem.indexOfScalarPos(u8, token, dot1 + 1, '.') orelse return error.BadIdToken;
    const header = try object(arena, try decode(arena, token[0..dot1]));
    if (!std.mem.eql(u8, str(header, "alg") orelse "", "RS256")) return error.BadIdToken;
    const sig = try decode(arena, token[dot2 + 1 ..]);
    const n = std.mem.trimStart(u8, try decode(arena, n_b64), &.{0});
    const key = rsa.PublicKey.fromBytes(try decode(arena, e_b64), n) catch return error.UnknownSigningKey;
    switch (n.len) {
        inline 256, 384, 512 => |len| {
            if (sig.len != len) return error.BadSignature;
            rsa.PKCS1v1_5Signature.verify(len, sig[0..len].*, token[0..dot2], key, Sha256) catch return error.BadSignature;
        },
        else => return error.UnknownSigningKey,
    }
    const claims = try object(arena, try decode(arena, token[dot1 + 1 .. dot2]));
    if (!std.mem.eql(u8, str(claims, "iss") orelse "", issuer)) return error.WrongIssuer;
    if (!audienceMatches(claims.get("aud"), audience)) return error.WrongAudience;
    const exp: i64 = if (claims.get("exp")) |v| (if (v == .integer) v.integer else 0) else 0;
    if (exp < now_s - 60) return error.Expired;
    if (nonce) |want| if (!std.mem.eql(u8, str(claims, "nonce") orelse "", want)) return error.NonceMismatch;
    return .{ .sub = str(claims, "sub") orelse return error.BadIdToken, .email = str(claims, "email") orelse "", .exp = exp };
}

/// Fetch OpenAI's JWKS, pick the key the token's `kid` names, and verify.
pub fn verify(io: Io, gpa: Allocator, arena: Allocator, token: []const u8, audience: []const u8, nonce: ?[]const u8, now_s: i64) !Claims {
    const dot1 = std.mem.indexOfScalar(u8, token, '.') orelse return error.BadIdToken;
    const kid = str(try object(arena, try decode(arena, token[0..dot1])), "kid") orelse return error.BadIdToken;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const res = try client.fetch(.{ .location = .{ .url = jwks_url }, .method = .GET, .response_writer = &aw.writer });
    if (res.status != .ok) return error.UnknownSigningKey;
    const keys = (try object(arena, aw.writer.buffered())).get("keys") orelse return error.UnknownSigningKey;
    if (keys != .array) return error.UnknownSigningKey;
    for (keys.array.items) |k| {
        if (k != .object or !std.mem.eql(u8, str(k.object, "kid") orelse "", kid)) continue;
        return verifyWithKey(arena, token, str(k.object, "n") orelse continue, str(k.object, "e") orelse continue, audience, nonce, now_s);
    }
    return error.UnknownSigningKey;
}

// A 2048-bit key and token made with openssl for these tests only:
// iss auth.openai.com, aud oaiapp_test, sub user-1, nonce n0, exp 2100-01-01.
const test_token = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImdyYWZmLXRlc3QiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2F1dGgub3BlbmFpLmNvbSIsImF1ZCI6Im9haWFwcF90ZXN0Iiwic3ViIjoidXNlci0xIiwiZW1haWwiOiJhQGV4YW1wbGUuY29tIiwiZXhwIjo0MTAyNDQ0ODAwLCJub25jZSI6Im4wIn0.fZDooG1-3My4XerEC_UcvTJ2aOLqUuB0Clk61W1NQMoPYJdOqhwgOmurE94MYz97CGmVoHsHVMzlZpHxBz78Fl4rg6fE2N0adoGzdUkgZyFClbtA5-r1nrqHLmbOuC6UzRQda35tzONViXC2gKBMBzedX1jkyeNb3OocEeygle93s6JSl6rIogX3mlxqTW0_hIqFG2mpruiCQc11c4w1_IYOBphewCJs6586nuO2Xu8AoKt7BB9IvmIhIgfNzufs6tpzmO6e0z9b4zrsXJcWgG-kzT7BjA-V9HWkSb8j9ke5-qm_P4Mo1qX7TLpo5IJsNx2LcwerWXeHdEV58gcugA";
const test_n = "3BnXtT30BbTxcaOT8ikBt_uq2BbhmNDOQ58iQ2NTBu2fHkc8V60jmAIPckEQmXdcX2an0Njy9qWkL8ZPVt81zxfPpvogf6Wv4udel8n--kgNE4uwm0ZJO8lCYA7dm5aBiCCttqvar8x-gQNQ08ozDPbfQt0m-_3Z091LbsszBcFiaxfyUR7pYAwiCeWv4_TOzylOi5bsZXF_Qeyo3T-TtEQdS1pDxySY4sRfNeHaC5NK3dO7_3h9eoe8WTQFclQ3FhPD69Qdd_UAQlWG2jwrkQxqh1j6U6O3Ugu0znLlYyAndv3RT4MQaHJyKy_iVZUw9JUR6Ae5z5voK_Wfd9fNuw";
const now_2026: i64 = 1_790_000_000;

test "ChatGPT ID token: a valid RS256 token verifies and yields its claims" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const claims = try verifyWithKey(arena.allocator(), test_token, test_n, "AQAB", "oaiapp_test", "n0", now_2026);
    try std.testing.expectEqualStrings("user-1", claims.sub);
    try std.testing.expectEqualStrings("a@example.com", claims.email);
    // Refresh responses carry no nonce: a null nonce skips only that check.
    _ = try verifyWithKey(arena.allocator(), test_token, test_n, "AQAB", "oaiapp_test", null, now_2026);
}

test "ChatGPT ID token: audience, nonce, expiry and signature failures are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.WrongAudience, verifyWithKey(a, test_token, test_n, "AQAB", "oaiapp_other", "n0", now_2026));
    try std.testing.expectError(error.NonceMismatch, verifyWithKey(a, test_token, test_n, "AQAB", "oaiapp_test", "n1", now_2026));
    try std.testing.expectError(error.Expired, verifyWithKey(a, test_token, test_n, "AQAB", "oaiapp_test", "n0", 4_200_000_000));
    // Same header and signature over a payload whose sub was changed.
    const forged_payload = "eyJpc3MiOiJodHRwczovL2F1dGgub3BlbmFpLmNvbSIsImF1ZCI6Im9haWFwcF90ZXN0Iiwic3ViIjoidXNlci0yIiwiZW1haWwiOiJhQGV4YW1wbGUuY29tIiwiZXhwIjo0MTAyNDQ0ODAwLCJub25jZSI6Im4wIn0";
    const dot1 = std.mem.indexOfScalar(u8, test_token, '.').?;
    const dot2 = std.mem.lastIndexOfScalar(u8, test_token, '.').?;
    const forged = try std.mem.concat(a, u8, &.{ test_token[0 .. dot1 + 1], forged_payload, test_token[dot2..] });
    try std.testing.expectError(error.BadSignature, verifyWithKey(a, forged, test_n, "AQAB", "oaiapp_test", "n0", now_2026));
    try std.testing.expectError(error.BadIdToken, verifyWithKey(a, "not-a-jwt", test_n, "AQAB", "oaiapp_test", "n0", now_2026));
}
