//! Quota caps and ChatGPT plan usage limits: a limit a retry cannot clear,
//! unlike transient throttling. Split out of agent_request_policy.zig for the
//! 600-line cap and re-exported there, so call sites keep saying `policy.`.

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
    return util.indexOfIgnoreCase(body, plan_usage_code_prefix) != null or
        util.indexOfIgnoreCase(body, "insufficient_quota") != null or
        util.indexOfIgnoreCase(body, "insufficient quota") != null or
        util.indexOfIgnoreCase(body, "exceeded your current quota") != null or
        util.indexOfIgnoreCase(body, "quota exceeded") != null;
}

/// ChatGPT plan usage (ADR 0221): `subscription_sharing_usage_limit_exceeded`
/// (the allowance is spent) and `subscription_sharing_usage_unavailable`. Both
/// can arrive mid-stream as response.failed; neither clears in seconds.
const plan_usage_code_prefix = "subscription_sharing_usage";

pub fn isPlanUsageLimit(code: ?[]const u8) bool {
    const c = code orelse return false;
    return std.mem.startsWith(u8, c, plan_usage_code_prefix);
}

test "isQuotaExceeded (#opencode-parity): billing cap detected, transient throttle not" {
    try std.testing.expect(isQuotaExceeded("{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"You exceeded your current quota\"}}"));
    try std.testing.expect(isQuotaExceeded("Quota Exceeded for this key"));
    try std.testing.expect(isQuotaExceeded("{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}"));
    try std.testing.expect(isQuotaExceeded("{\"error\":{\"code\":\"subscription_sharing_usage_unavailable\"}}"));
    try std.testing.expect(isPlanUsageLimit("subscription_sharing_usage_unavailable"));
    try std.testing.expect(!isPlanUsageLimit("rate_limit_exceeded") and !isPlanUsageLimit(null));
    // transient rate-limit -> NOT a quota cap; must still retry
    try std.testing.expect(!isQuotaExceeded("Rate limit reached. Please try again in 20s."));
    try std.testing.expect(!isQuotaExceeded("429 too many requests"));
}
