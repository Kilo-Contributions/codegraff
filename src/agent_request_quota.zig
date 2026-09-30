//! Quota caps and ChatGPT plan errors: a limit a retry cannot clear, unlike
//! transient throttling, and the plan codes OpenAI says to retry or stop on.
//! Split out of agent_request_policy.zig for the 600-line cap; the quota
//! checks are re-exported there, so their call sites keep saying `policy.`.

const std = @import("std");
const util = @import("util.zig");

/// #opencode-parity: a 429 body naming a billing/quota cap (OpenAI insufficient_quota,
/// "exceeded your current quota", "quota exceeded") — a usage limit a retry can't
/// clear, unlike transient rate-limit throttling — so we fail fast + fail over rather
/// than burning retry attempts.
/// The phrase agent_request stamps into `last_api_error` when a 429 body named
/// a billing/credit cap rather than transient throttling. It is a const, not a
/// literal spelled twice, because a second reader now depends on it: a worker's
/// in-turn retry ladder (subagent_retry.hardQuotaCap) reads this marker back
/// out of the message to tell "the account is capped" — where re-asking is
/// pure waste — from "slow down", where re-asking is the whole point.
pub const quota_cap_marker = "quota/billing cap";

pub fn isQuotaExceeded(body: []const u8) bool {
    // ChatGPT plan usage limits (ADR 0221): stop, never retry into them.
    return util.indexOfIgnoreCase(body, plan_limit_code) != null or
        util.indexOfIgnoreCase(body, "insufficient_quota") != null or
        util.indexOfIgnoreCase(body, "insufficient quota") != null or
        util.indexOfIgnoreCase(body, "exceeded your current quota") != null or
        util.indexOfIgnoreCase(body, "quota exceeded") != null;
}

// ChatGPT plan errors, as OpenAI's errors-and-recovery page classifies them
// (ADR 0221). Only a spent allowance is a limit (429, resets after hours).
const plan_limit_code = "subscription_sharing_usage_limit_exceeded";

pub fn isPlanUsageLimit(code: ?[]const u8) bool {
    return std.mem.eql(u8, code orelse return false, plan_limit_code);
}

/// Any ChatGPT plan code. None of them is a gateway flake: each is either a
/// temporary outage with its own ladder or a request to stop.
pub fn isPlanCode(code: ?[]const u8) bool {
    return std.mem.startsWith(u8, code orelse return false, "subscription_sharing_");
}

/// Usage or user data temporarily unavailable (503): keep the credentials and
/// retry with bounded backoff, like an overload.
pub fn isPlanTransient(code: ?[]const u8) bool {
    const c = code orelse return false;
    return std.mem.eql(u8, c, "subscription_sharing_usage_unavailable") or
        std.mem.eql(u8, c, "subscription_sharing_user_unavailable");
}

/// Every other plan code stops the turn: a spent allowance (429), an account,
/// workspace or policy that is not eligible (403), an unsupported route (403)
/// or capability (400), or a user the route no longer accepts (401, which the
/// auth refresh sees first). A new code stops too rather than spend usage.
pub fn isPlanStop(code: ?[]const u8) bool {
    return isPlanCode(code) and !isPlanTransient(code);
}

test "isQuotaExceeded (#opencode-parity): billing cap detected, transient throttle not" {
    try std.testing.expect(isQuotaExceeded("{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"You exceeded your current quota\"}}"));
    try std.testing.expect(isQuotaExceeded("Quota Exceeded for this key"));
    try std.testing.expect(isQuotaExceeded("{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}"));
    // transient rate-limit -> NOT a quota cap; must still retry
    try std.testing.expect(!isQuotaExceeded("Rate limit reached. Please try again in 20s."));
    try std.testing.expect(!isQuotaExceeded("429 too many requests"));
}

test "ChatGPT plan codes follow OpenAI's recovery table" {
    // A spent allowance stops; an unavailable usage or user check is a 503 to
    // retry, not a limit; an ineligible account or unsupported request stops.
    try std.testing.expect(isPlanUsageLimit("subscription_sharing_usage_limit_exceeded"));
    try std.testing.expect(!isPlanUsageLimit("subscription_sharing_usage_unavailable"));
    try std.testing.expect(!isQuotaExceeded("{\"error\":{\"code\":\"subscription_sharing_usage_unavailable\"}}"));
    try std.testing.expect(isPlanTransient("subscription_sharing_usage_unavailable"));
    try std.testing.expect(isPlanTransient("subscription_sharing_user_unavailable"));
    try std.testing.expect(!isPlanTransient("subscription_sharing_usage_limit_exceeded"));
    try std.testing.expect(!isPlanStop("subscription_sharing_usage_unavailable"));
    for ([_][]const u8{
        "subscription_sharing_usage_limit_exceeded",
        "subscription_sharing_user_not_eligible",
        "subscription_sharing_route_not_supported",
        "subscription_sharing_unsupported_capability",
        "subscription_sharing_invalid_user",
    }) |c| try std.testing.expect(isPlanStop(c));
    try std.testing.expect(!isPlanCode("rate_limit_exceeded") and !isPlanCode(null) and !isPlanStop(null));
}
