//! ADR 0253: an interactive session signs in to ChatGPT again by itself.
//!
//! OpenAI currently refuses every renewal of a Sign in with ChatGPT session
//! (`invalid_grant`), for graff and for every other client that sends the
//! documented refresh request, so a sign-in lasts about an hour. When a
//! request's credential is rejected and the refresh could not help, a session
//! with a person at the terminal opens the same browser sign-in as
//! `/login chatgpt`, waits a bounded time, and retries the request with the
//! new token. One unfinished attempt ends it for the process: later requests
//! fail with the usual "sign in again" error instead of reopening the browser.
//! `-p`, piped and `--json` runs, ACP sessions (the client owns sign-in) and
//! sub-agents never open a browser.

const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const oauth = @import("oauth.zig");

/// How long a request waits for the browser sign-in.
pub const wait_s: i64 = 180;

/// Set once a sign-in started here did not finish.
var gave_up = false;

/// Whether a rejected request may open the browser sign-in.
pub fn eligible(provider_id: []const u8, no_human: bool, json: bool, unattended: bool, sub: bool, has_out: bool, home: []const u8) bool {
    return std.mem.eql(u8, provider_id, "chatgpt-new") and !no_human and !json and !unattended and !sub and has_out and home.len > 0;
}

/// After the refresh failed: sign in again and adopt the new token. True when
/// the request should be retried.
pub fn renewed(self: *Agent) bool {
    const main_mod = @import("main.zig");
    if (gave_up or !eligible(self.provider.id, @import("ask_user.zig").g_no_human, main_mod.json_mode, main_mod.unattended, self.sub, self.out != null, self.home)) return false;
    self.say("\n[ChatGPT sign-in expired — opening your browser to sign in again; this request waits up to {d} min]\n", .{@divTrunc(wait_s, 60)}) catch {};
    if (!signInWithin(self.io, self.gpa, self.home)) return giveUp(self);
    // The sign-in wrote a new token to disk: a forced load with the rejected
    // token as `stale` adopts it without another refresh.
    const fresh = oauth.refreshOAuthKey(self.io, self.gpa, self.scratchAlloc(), self.home, "chatgpt-new", true, self.provider.api_key, self.provider.account) orelse return giveUp(self);
    if (std.mem.eql(u8, fresh.key, self.provider.api_key)) return giveUp(self);
    @import("agent_request_policy.zig").adoptFreshAuth(self, fresh);
    if (self.tracer) |tr| tr.note("oauth_refresh", "ChatGPT sign-in renewed in place, retrying");
    return true;
}

fn giveUp(self: *Agent) bool {
    gave_up = true;
    self.say("[ChatGPT sign-in did not finish — run `/login chatgpt` when you are ready]\n", .{}) catch {};
    return false;
}

const Done = union(enum) { signed_in: bool, timeout };

fn loginTask(io: Io, gpa: std.mem.Allocator, home: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    @import("oauth_chatgpt.zig").login(io, gpa, arena_state.allocator(), home) catch return false;
    return true;
}

fn deadline(io: Io) void {
    io.sleep(.fromSeconds(wait_s), .awake) catch {};
}

/// Run the browser sign-in, giving up after `wait_s`. Cancelling the login
/// task closes its loopback listener, so a late redirect finds nothing.
fn signInWithin(io: Io, gpa: std.mem.Allocator, home: []const u8) bool {
    var buf: [2]Done = undefined;
    var sel: Io.Select(Done) = .init(io, &buf);
    sel.concurrent(.signed_in, loginTask, .{ io, gpa, home }) catch return loginTask(io, gpa, home);
    sel.concurrent(.timeout, deadline, .{io}) catch {
        const only = sel.await() catch return false;
        sel.cancelDiscard();
        return only == .signed_in and only.signed_in;
    };
    const first = sel.await() catch {
        sel.cancelDiscard();
        return false;
    };
    sel.cancelDiscard();
    return first == .signed_in and first.signed_in;
}

test "eligible: only an interactive root ChatGPT session opens the browser" {
    try std.testing.expect(eligible("chatgpt-new", false, false, false, false, true, "/home/u"));
    try std.testing.expect(!eligible("codex", false, false, false, false, true, "/home/u"));
    try std.testing.expect(!eligible("chatgpt-new", true, false, false, false, true, "/home/u")); // -p / piped
    try std.testing.expect(!eligible("chatgpt-new", false, true, false, false, true, "/home/u")); // --json / ACP
    try std.testing.expect(!eligible("chatgpt-new", false, false, true, false, true, "/home/u")); // ACP (unattended)
    try std.testing.expect(!eligible("chatgpt-new", false, false, false, true, true, "/home/u")); // sub-agent
    try std.testing.expect(!eligible("chatgpt-new", false, false, false, false, false, "/home/u")); // no terminal output
    try std.testing.expect(!eligible("chatgpt-new", false, false, false, false, true, "")); // no home
}
