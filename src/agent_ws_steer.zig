//! GPT-6 mid-turn steering over the Responses WebSocket (`response.steer`).
//!
//! A follow-up typed while a GPT-6 turn streams goes out on the same socket as
//! `{type: response.steer, previous_response_id, input}` instead of waiting
//! for the turn to end. What the server does with it (OpenAI's steering guide;
//! the Codex route behaves the same):
//!
//!   * `response.steer.accepted` queues it. The server finishes the output item
//!     in progress, ends the response (`incomplete` with reason `steered`, or
//!     `completed` when that item was its last) and starts a continuation, a
//!     new response on this socket that carries the update. Keep reading and
//!     never send another response.create for it; later steers target the
//!     continuation.
//!   * A response that ends with client tool calls keeps an accepted steer
//!     waiting (`response.steer.pending`): the server prepends it to the next
//!     response.create chained on that response, the one with the tool
//!     outputs. Stop reading so the tool loop runs, and never resend it.
//!   * `response.steer.failed` means it was not applied and never will be. The
//!     text goes back on the follow-up queue for the next step boundary;
//!     `steering_not_supported` turns steering off for the session.
//!
//! An applied steer joins history as a user message where the server applied
//! it (ahead of the continuation's items, or after the calls whose outputs it
//! precedes), so a full resend, /resume and compaction keep it. A steer lives
//! only on this socket: one the returned body does not carry (a failed
//! response, a stall, a drop, Esc) goes back on the queue.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const steer_now = @import("steer_now.zig");
const Agent = @import("agent.zig").Agent;
const isStreamEnd = @import("agent_stream.zig").isStreamEnd;

/// A steer the server applied, as a line of the reassembled body:
/// parseResponses turns it into a user message at that point of the output.
/// graff's own event; it never goes on the wire.
pub const applied_type = "graff.steer";

pub fn modelSupports(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gpt-6");
}

/// Set by a `steering_not_supported` failure: the rest of the session
/// supersedes the reply instead (steer_now), as for models without steering.
pub var g_unsupported = false;

/// GPT-6 on the routes that implement steering (Platform OpenAI, Codex and
/// the ChatGPT plan route, ADR 0221). Other sockets serving GPT-6 names
/// supersede the reply instead.
pub fn active(provider_id: []const u8, model: []const u8) bool {
    if (g_unsupported or !modelSupports(model)) return false;
    return std.mem.eql(u8, provider_id, "codex") or std.mem.eql(u8, provider_id, "openai") or
        std.mem.eql(u8, provider_id, "chatgpt-new");
}

/// The root's own turn request on a steering route: the requests a typed
/// follow-up can steer (not a compaction, title or child call).
pub fn rootTurnOnSteeringRoute(self: anytype) bool {
    if (self.sub or self.call_kind != .root or self.compaction_request or self.server_compaction_request) return false;
    return active(self.provider.id, self.provider.model);
}

/// This request steers: a root turn on a steering route whose body carries no
/// server-compaction directive (the two exclude each other; see
/// agent_server_compact.directive). Any other request supersedes the reply.
pub fn steers(self: anytype) bool {
    return rootTurnOnSteeringRoute(self) and @import("agent_server_compact.zig").directive(self) == null;
}

/// Who actually serves a Responses WebSocket. Platform OpenAI only for GPT-6
/// (mid-turn `response.steer`); GPT-5.6 stays HTTP SSE. Codex/xAI/gateway
/// keep their existing sockets. The ChatGPT plan route (ADR 0221) serves one
/// for every model it lists; its HTTP path refuses previous_response_id, so
/// the socket is what chains. 426 still latches SSE.
pub fn providerHasWs(id: []const u8, model: []const u8) bool {
    if (std.mem.eql(u8, id, "codex") or std.mem.eql(u8, id, "xai") or std.mem.eql(u8, id, "codegraff")) return true;
    if (std.mem.eql(u8, id, "chatgpt-new")) return true;
    return std.mem.eql(u8, id, "openai") and modelSupports(model);
}

const State = enum { sent, accepted, placed, failed };

const Steer = struct {
    /// Page-allocated, as queued (steer_input, steer_now.send).
    text: []const u8,
    /// The server's steer.id once accepted (gpa); a later failure names it.
    id: []const u8 = "",
    state: State = .sent,
};

/// One request's steering, from its first frame to settle().
pub const Session = struct {
    /// Where the next steer goes: the newest `response.created` id (gpa).
    live_id: []const u8 = "",
    /// live_id before its `response.created`, streaming, or past its end.
    phase: enum { waiting, running, ended } = .waiting,
    /// live_id ended `incomplete` with reason `steered`: a continuation follows.
    steered: bool = false,
    /// Client tool calls in live_id's output. An accepted steer then waits for
    /// their outputs instead of opening a continuation.
    calls: u32 = 0,
    /// A failed steer pauses steering until the next response starts.
    paused: bool = false,
    /// The stream ended cleanly, so the placed steers ride the returned body.
    committed: bool = false,
    steers: std.ArrayList(Steer) = .empty,

    fn count(st: *const Session, state: State) usize {
        var n: usize = 0;
        for (st.steers.items) |s| n += @intFromBool(s.state == state);
        return n;
    }

    fn oldest(st: *Session, state: State) ?*Steer {
        for (st.steers.items) |*s| if (s.state == state) return s;
        return null;
    }

    fn named(st: *Session, id: []const u8) ?*Steer {
        if (id.len == 0) return null;
        for (st.steers.items) |*s| {
            if ((s.state == .sent or s.state == .accepted) and std.mem.eql(u8, s.id, id)) return s;
        }
        return null;
    }

    /// Hand back every steer the returned body does not carry (all of them
    /// when the stream failed, since the body is dropped and the request
    /// retries or the turn ends; else any the server never applied), then
    /// free the rest.
    pub fn settle(st: *Session, gpa: Allocator) void {
        var back: std.ArrayList([]const u8) = .empty;
        defer back.deinit(gpa);
        for (st.steers.items) |s| {
            gpa.free(s.id);
            if (s.state == .failed) continue; // the queue took it back when it failed
            if (s.state == .placed and st.committed) {
                std.heap.page_allocator.free(s.text);
                continue;
            }
            back.append(gpa, s.text) catch std.heap.page_allocator.free(s.text);
        }
        steer_now.requeue(back.items);
        st.steers.deinit(gpa);
        gpa.free(st.live_id);
        st.* = .{};
    }
};

const Kind = enum { other, created, call, accepted, pending, failed, ended, broke };

const Event = struct {
    kind: Kind = .other,
    /// response.id (created) or steer.id (accepted, failed).
    id: []const u8 = "",
    /// The failure's error code.
    code: []const u8 = "",
    /// An `incomplete` end whose reason is `steered`.
    steered: bool = false,
};

fn get(v: ?Value, name: []const u8) ?Value {
    const o = v orelse return null;
    return if (o == .object) o.object.get(name) else null;
}

fn str(v: ?Value) []const u8 {
    const s = v orelse return "";
    return if (s == .string) s.string else "";
}

fn classify(scratch: Allocator, frame: []const u8) Event {
    const eql = std.mem.eql;
    const v = std.json.parseFromSliceLeaky(Value, scratch, frame, .{ .allocate = .alloc_always }) catch return .{};
    const ty = str(get(v, "type"));
    if (eql(u8, ty, "response.created")) return .{ .kind = .created, .id = str(get(get(v, "response"), "id")) };
    if (eql(u8, ty, "response.output_item.done")) {
        const item = str(get(get(v, "item"), "type"));
        const call = eql(u8, item, "function_call") or eql(u8, item, "custom_tool_call");
        return .{ .kind = if (call) .call else .other };
    }
    if (eql(u8, ty, "response.steer.accepted")) return .{ .kind = .accepted, .id = str(get(get(v, "steer"), "id")) };
    if (eql(u8, ty, "response.steer.pending")) return .{ .kind = .pending };
    if (eql(u8, ty, "response.steer.failed")) return .{
        .kind = .failed,
        .id = str(get(get(v, "steer"), "id")),
        .code = str(get(get(v, "error"), "code")),
    };
    if (eql(u8, ty, "response.completed") or eql(u8, ty, "response.incomplete")) {
        const reason = str(get(get(get(v, "response"), "incomplete_details"), "reason"));
        return .{ .kind = .ended, .steered = eql(u8, reason, "steered") };
    }
    if (eql(u8, ty, "response.failed") or eql(u8, ty, "error")) return .{ .kind = .broke };
    return .{};
}

/// Drive one inbound WS frame; true when this request's stream is done.
/// Applied steers are written into `body`, the reassembled stream the caller
/// returns. `text_seen` is the caller's inter-frame budget signal: a
/// continuation thinks afresh, so it starts over.
pub fn tick(self: anytype, client: anytype, frame: []const u8, st: *Session, body: *Io.Writer, text_seen: *bool) !bool {
    const scratch = self.scratchAlloc();
    if (!steers(self))
        return isStreamEnd(scratch, self.provider.kind, try std.mem.concat(scratch, u8, &.{ "data: ", frame }));
    const ev = classify(scratch, frame);
    switch (ev.kind) {
        .created => {
            if (st.phase != .waiting) text_seen.* = false;
            try place(self, st, body); // accepted steers open the continuation
            self.gpa.free(st.live_id);
            st.live_id = "";
            st.live_id = try self.gpa.dupe(u8, ev.id);
            st.phase = .running;
            st.steered = false;
            st.calls = 0;
            st.paused = false;
        },
        .call => st.calls += 1,
        .accepted => if (st.oldest(.sent)) |s| {
            s.state = .accepted;
            s.id = self.gpa.dupe(u8, ev.id) catch "";
            note(self, "response.steer accepted");
        },
        .pending => try place(self, st, body),
        .failed => fail(self, st, ev),
        .ended => {
            st.phase = .ended;
            st.steered = ev.steered;
        },
        .broke => return true, // not committed: settle hands every steer back
        .other => {},
    }
    if (st.phase == .running and !st.paused and st.live_id.len > 0) flush(self, client, st);
    return finished(self, st, body);
}

/// Once the live response has ended: is this request's stream done?
fn finished(self: anytype, st: *Session, body: *Io.Writer) !bool {
    if (st.phase != .ended) return false;
    if (st.count(.sent) > 0) return false; // the server still owes each an accepted or a failed
    if (st.calls > 0) {
        try place(self, st, body); // they wait for the tool outputs; the server prepends them
    } else if (st.steered or st.count(.accepted) > 0) return false; // a continuation carries them
    st.committed = true;
    return true;
}

/// Send each queued soft follow-up as a steer on the live response. A force
/// entry stays queued for the interrupt path, as in turn_inbox.
fn flush(self: anytype, client: anytype, st: *Session) void {
    while (@import("turn_inbox.zig").popSteerSoft()) |entry| {
        if (entry.text.len == 0) {
            std.heap.page_allocator.free(entry.text);
            continue;
        }
        const frame = buildSteerFrame(self.gpa, st.live_id, entry.text) catch return steer_now.requeue(&.{entry.text});
        defer self.gpa.free(frame);
        st.steers.append(self.gpa, .{ .text = entry.text }) catch return steer_now.requeue(&.{entry.text});
        client.sendText(frame) catch {
            _ = st.steers.pop(); // a dead socket: the read loop fails next
            return steer_now.requeue(&.{entry.text});
        };
        note(self, "a follow-up went out as response.steer");
    }
}

/// Write each accepted steer into the body where the server applied it, and
/// show it there: the reply it interrupted closes, then the steer's own line.
fn place(self: anytype, st: *Session, body: *Io.Writer) !void {
    var closed = false;
    for (st.steers.items) |*s| {
        if (s.state != .accepted) continue;
        var w: std.json.Stringify = .{ .writer = body };
        try body.writeAll("data: ");
        try w.beginObject();
        try w.objectField("type");
        try w.write(applied_type);
        try w.objectField("text");
        try w.write(s.text);
        try w.endObject();
        try body.writeByte('\n');
        s.state = .placed;
        note(self, if (st.phase == .ended and st.calls > 0) "a steer joined history after the tool calls it waits on" else "a steer joined history ahead of the continuation");
        if (@TypeOf(self) != *Agent) continue;
        const sink = @import("engine_sink.zig").forAgent(self);
        if (!closed) sink.emit(self.io, .{ .stream_complete = .{ .streamed_text = self.streamed_text } });
        closed = true;
        sink.emit(self.io, .{ .session_notice = .{ .text = s.text, .tone = .dim } });
    }
}

fn fail(self: anytype, st: *Session, ev: Event) void {
    // Nothing in flight under that id: an earlier request's steer, not ours to hand back.
    const s = st.named(ev.id) orelse st.oldest(.sent) orelse return;
    s.state = .failed;
    steer_now.requeue(&.{s.text}); // the next step boundary or turn delivers it
    st.paused = true;
    if (std.mem.eql(u8, ev.code, "steering_not_supported")) g_unsupported = true;
    var buf: [128]u8 = undefined;
    note(self, std.fmt.bufPrint(&buf, "response.steer failed ({s}); the follow-up waits for the next step", .{ev.code}) catch "response.steer failed");
}

fn note(self: anytype, msg: []const u8) void {
    if (@TypeOf(self) != *Agent) return;
    if (self.tracer) |tr| tr.note("steer", msg);
}

/// The responses a steer ended before the body's last one used tokens too:
/// parseResponses keeps their usage aside so the context meter stays on the
/// last response (which read everything they did). Bill them first, so the
/// cache readout ends on the last one.
pub fn billEnded(self: *Agent, response: std.json.ObjectMap) void {
    const ended = response.get("steered_usage") orelse return;
    if (ended != .array) return;
    const usageInt = @import("agent_context.zig").usageInt;
    for (ended.array.items) |u| {
        if (u != .object) continue;
        const in = usageInt(u.object, "input_tokens");
        var cached: i64 = 0;
        var written: i64 = 0;
        if (u.object.get("input_tokens_details")) |d| if (d == .object) {
            cached = usageInt(d.object, "cached_tokens");
            written = usageInt(d.object, "cache_write_tokens");
        };
        self.recordCost(@max(in - cached - written, 0), cached, written, usageInt(u.object, "output_tokens"));
        // Its own usage line: the trace keeps one pending usage per call.
        if (self.tracer) |tr| @import("usage_trace.zig").emit(tr, self.label, self.sub, self.provider.model);
    }
}

pub fn buildSteerFrame(gpa: Allocator, response_id: []const u8, input: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("type");
    try s.write("response.steer");
    try s.objectField("previous_response_id");
    try s.write(response_id);
    try s.objectField("input");
    try s.write(input);
    try s.endObject();
    return aw.toOwnedSlice();
}

test "modelSupports is gpt-6 only" {
    try std.testing.expect(modelSupports("gpt-6-astra"));
    try std.testing.expect(modelSupports("gpt-6"));
    try std.testing.expect(!modelSupports("gpt-5.6-sol"));
    try std.testing.expect(!modelSupports("gpt-5.6"));
}

test "providerHasWs: Platform OpenAI GPT-6 only; Codex always" {
    try std.testing.expect(providerHasWs("openai", "gpt-6-astra"));
    try std.testing.expect(!providerHasWs("openai", "gpt-5.6"));
    try std.testing.expect(!providerHasWs("openai", "gpt-5.6-luna"));
    try std.testing.expect(providerHasWs("codex", "gpt-5.6-sol"));
    try std.testing.expect(providerHasWs("codex", "gpt-6-astra"));
    try std.testing.expect(providerHasWs("xai", "grok-4.6"));
    try std.testing.expect(providerHasWs("codegraff", "gpt-6-astra"));
    try std.testing.expect(providerHasWs("chatgpt-new", "gpt-6.1-sol"));
    try std.testing.expect(providerHasWs("chatgpt-new", "gpt-5.5"));
    try std.testing.expect(modelSupports("gpt-6.1-sol")); // steering rides the same socket
}

test "buildSteerFrame is type + previous_response_id + input" {
    const gpa = std.testing.allocator;
    const frame = try buildSteerFrame(gpa, "resp_1", "keep it small");
    defer gpa.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"type\":\"response.steer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"previous_response_id\":\"resp_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"input\":\"keep it small\"") != null);
}

test {
    _ = @import("agent_ws_steer_tests.zig");
}
