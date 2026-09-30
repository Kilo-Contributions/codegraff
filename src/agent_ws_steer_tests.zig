//! agent_ws_steer, frame by frame, in the orders the Codex route sends them.

const std = @import("std");
const Io = std.Io;
const steer = @import("agent_ws_steer.zig");
const main_mod = @import("main.zig");
const repl_glue = @import("repl_glue.zig");
const engine_sink = @import("engine_sink.zig");
const Agent = @import("agent.zig").Agent;
const page = std.heap.page_allocator;
const expect = std.testing.expect;

const created1 = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\"}}";
const created2 = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_2\",\"status\":\"in_progress\"}}";
const accepted = "{\"type\":\"response.steer.accepted\",\"steer\":{\"id\":\"steer_1\",\"previous_response_id\":\"resp_1\"}}";
const bees = "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"bees\"}]}}";
const ants = "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ants\"}]}}";
const thought = "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"summary\":[]}}";
const call = "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"get_project_status\",\"arguments\":\"{}\"}}";
const done1 = "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":100,\"output_tokens\":10,\"total_tokens\":110}}}";
const steered1 = "{\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_1\",\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"steered\"},\"usage\":{\"input_tokens\":100,\"output_tokens\":5,\"total_tokens\":105}}}";
const done2 = "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"status\":\"completed\",\"usage\":{\"input_tokens\":120,\"output_tokens\":20,\"total_tokens\":140}}}";
const pending = "{\"type\":\"response.steer.pending\",\"steer\":{\"id\":\"steer_1\",\"previous_response_id\":\"resp_1\"},\"reason\":\"waiting_for_required_input\",\"required_input\":[{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"name\":\"get_project_status\"}]}";
const invalid = "{\"type\":\"response.steer.failed\",\"steer\":{\"previous_response_id\":\"resp_1\"},\"error\":{\"code\":\"invalid_input\",\"type\":\"invalid_request_error\"}}";
const unsupported = "{\"type\":\"response.steer.failed\",\"steer\":{\"previous_response_id\":\"resp_1\"},\"error\":{\"code\":\"steering_not_supported\",\"type\":\"invalid_request_error\"}}";

const drop = struct {
    fn emit(_: *anyopaque, _: engine_sink.Stamped) void {}
};
const drop_vt = engine_sink.VTable{ .emit = drop.emit, .durable = false };

const Socket = struct {
    sent: std.ArrayList(u8) = .empty,
    frames: usize = 0,
    pub fn sendText(sock: *Socket, frame: []const u8) !void {
        sock.frames += 1;
        try sock.sent.appendSlice(std.testing.allocator, frame);
        try sock.sent.append(std.testing.allocator, '\n');
    }
};

/// One request's read loop: each frame joins the body, then steering sees it
/// (agent_ws.postResponsesWs's order).
const Run = struct {
    arena_state: std.heap.ArenaAllocator,
    agent: Agent,
    sock: Socket,
    st: steer.Session,
    body: Io.Writer.Allocating,
    text_seen: bool,

    fn start(r: *Run, model: []const u8) !void {
        r.arena_state = .init(std.testing.allocator);
        r.agent = try @import("agent_request_body_responses.zig").testAgentFor(r.arena_state.allocator(), "codex", .responses, model);
        r.agent.sink = .{ .ctx = undefined, .vt = &drop_vt };
        r.sock = .{};
        r.st = .{};
        r.body = .init(std.testing.allocator);
        r.text_seen = true;
    }

    fn feed(r: *Run, frame: []const u8) !bool {
        try r.body.writer.print("data: {s}\n", .{frame});
        return steer.tick(&r.agent, &r.sock, frame, &r.st, &r.body.writer, &r.text_seen);
    }

    /// The items stepResponses would append to history, in order.
    fn output(r: *Run) ![]std.json.Value {
        return switch (try @import("agent_responses.zig").parseResponses(&r.agent, r.body.written())) {
            .ok => |root| root.get("output").?.array.items,
            .err => error.TestUnexpectedResult,
        };
    }

    fn end(r: *Run) void {
        r.st.settle(std.testing.allocator);
        r.body.deinit();
        r.sock.sent.deinit(std.testing.allocator);
        r.arena_state.deinit();
    }
};

fn clearQueue() void {
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    for (main_mod.g_steer_queue.items) |e| page.free(e.text);
    main_mod.g_steer_queue.clearRetainingCapacity();
}

fn enqueue(text: []const u8, force: bool) !void {
    const owned = try page.dupe(u8, text);
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    try main_mod.g_steer_queue.append(page, .{ .text = owned, .force = force });
}

fn expectQueue(expected: []const []const u8) !void {
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    const q = main_mod.g_steer_queue.items;
    try std.testing.expectEqual(expected.len, q.len);
    for (expected, q) |want, got| try std.testing.expectEqualStrings(want, got.text);
}

fn userText(item: std.json.Value) []const u8 {
    if (item != .object) return "";
    const role = item.object.get("role") orelse return "";
    if (role != .string or !std.mem.eql(u8, role.string, "user")) return "";
    const content = item.object.get("content") orelse return "";
    return if (content == .string) content.string else "";
}

test "steer mid-reply: accepted, the reply completes, a continuation carries it, history holds it between them" {
    clearQueue();
    defer clearQueue();
    var r: Run = undefined;
    try r.start("gpt-6-sol");
    defer r.end();

    try enqueue("list ants instead", false);
    try expect(!try r.feed(created1));
    try std.testing.expectEqual(@as(usize, 1), r.sock.frames);
    try expect(std.mem.indexOf(u8, r.sock.sent.items, "\"previous_response_id\":\"resp_1\"") != null);
    try expect(std.mem.indexOf(u8, r.sock.sent.items, "\"input\":\"list ants instead\"") != null);
    try expect(!try r.feed(accepted));
    try expect(!try r.feed(bees));
    try expect(!try r.feed(done1)); // the continuation is still due
    try expect(!try r.feed(created2));
    try expect(!r.text_seen); // the continuation's budget starts over
    try expect(!try r.feed(ants));
    try expect(try r.feed(done2));
    try expect(r.st.committed);

    const out = try r.output();
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("list ants instead", userText(out[1]));
    try expect(@import("session_wake.zig").isNotice(out[1]));
    const parsed = (try @import("agent_responses.zig").parseResponses(&r.agent, r.body.written())).ok;
    try std.testing.expectEqualStrings("resp_2", parsed.get("id").?.string);
    try std.testing.expectEqual(@as(i64, 120), parsed.get("usage").?.object.get("input_tokens").?.integer);
    try std.testing.expectEqual(@as(usize, 1), parsed.get("steered_usage").?.array.items.len);
    try expectQueue(&.{});
}

test "steer while reasoning: the response ends incomplete:steered and the continuation answers it" {
    clearQueue();
    defer clearQueue();
    var r: Run = undefined;
    try r.start("gpt-6-sol");
    defer r.end();

    try enqueue("write about ants", false);
    try expect(!try r.feed(created1));
    try expect(!try r.feed(accepted));
    try expect(!try r.feed(thought));
    try expect(!try r.feed(steered1));
    try expect(!try r.feed(created2));
    try expect(!try r.feed(thought));
    try expect(!try r.feed(ants));
    try expect(try r.feed(done2));
    const out = try r.output();
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqualStrings("write about ants", userText(out[1]));
}

test "steer that meets a tool call waits for its output: after the call in history, no wait for the pending notice" {
    clearQueue();
    defer clearQueue();
    var r: Run = undefined;
    try r.start("gpt-6-sol");
    defer r.end();

    try enqueue("keep it to two weeks", false);
    try expect(!try r.feed(created1));
    try expect(!try r.feed(accepted));
    try expect(!try r.feed(call));
    // The server holds the steer for the tool output (and prepends it there),
    // so the tool loop runs now; response.steer.pending may follow later.
    try expect(try r.feed(done1));
    const out = try r.output();
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("function_call", out[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("keep it to two weeks", userText(out[1]));

    // The next request's read loop meets that notice first; it ends nothing.
    var next: Run = undefined;
    try next.start("gpt-6-sol");
    defer next.end();
    try expect(!try next.feed(pending));
    try expect(!try next.feed(created2));
    try expect(!try next.feed(ants));
    try expect(try next.feed(done2));
}

test "a failed steer goes back on the queue and waits: no resend on the same response" {
    clearQueue();
    defer clearQueue();
    var r: Run = undefined;
    try r.start("gpt-6-sol");
    defer r.end();

    try enqueue("also add tests", false);
    try expect(!try r.feed(created1));
    try std.testing.expectEqual(@as(usize, 1), r.sock.frames);
    try expect(!try r.feed(invalid));
    try expectQueue(&.{"also add tests"});
    try expect(!try r.feed(bees));
    try std.testing.expectEqual(@as(usize, 1), r.sock.frames); // paused for this response
    try expect(try r.feed(done1));
    r.st.settle(std.testing.allocator);
    try expectQueue(&.{"also add tests"}); // delivered at the next step boundary instead
}

test "steering_not_supported turns steering off for the session" {
    clearQueue();
    defer clearQueue();
    defer steer.g_unsupported = false;
    var r: Run = undefined;
    try r.start("gpt-6-sol");
    defer r.end();

    try enqueue("stop and summarize", false);
    try expect(!try r.feed(created1));
    try expect(!try r.feed(unsupported));
    try expect(!steer.active("codex", "gpt-6-sol"));
    try expectQueue(&.{"stop and summarize"}); // steer_now supersedes the reply with it
    try expect(try r.feed(done1));
}

test "several steers accepted before one continuation go into history in order" {
    clearQueue();
    defer clearQueue();
    var r: Run = undefined;
    try r.start("gpt-6-sol");
    defer r.end();

    for ([_][]const u8{ "one", "two", "three" }) |t| try enqueue(t, false);
    try expect(!try r.feed(created1));
    try std.testing.expectEqual(@as(usize, 3), r.sock.frames);
    for (0..3) |_| try expect(!try r.feed(accepted));
    try expect(!try r.feed(bees));
    try expect(!try r.feed(done1));
    try expect(!try r.feed(created2));
    try expect(!try r.feed(ants));
    try expect(try r.feed(done2));
    const out = try r.output();
    try std.testing.expectEqual(@as(usize, 5), out.len);
    for ([_][]const u8{ "one", "two", "three" }, out[1..4]) |want, got| try std.testing.expectEqualStrings(want, userText(got));
}

test "a steer sent as the reply ends: keep reading until the server answers it" {
    clearQueue();
    defer clearQueue();
    var r: Run = undefined;
    try r.start("gpt-6-sol");
    defer r.end();

    try expect(!try r.feed(created1));
    try enqueue("one more thing", false);
    try expect(!try r.feed(bees)); // goes out here
    try expect(!try r.feed(done1)); // sent, not yet answered
    try expect(!try r.feed(accepted)); // a completed response still gets a continuation
    try expect(!try r.feed(created2));
    try expect(!try r.feed(ants));
    try expect(try r.feed(done2));
    try std.testing.expectEqualStrings("one more thing", userText((try r.output())[1]));
}

test "the terminal frame carries no steer, and a force entry stays for the interrupt path" {
    clearQueue();
    defer clearQueue();
    var r: Run = undefined;
    try r.start("gpt-6-sol");
    defer r.end();

    try enqueue("stop", true);
    try expect(!try r.feed(created1));
    try expect(!try r.feed(bees));
    try std.testing.expectEqual(@as(usize, 0), r.sock.frames);
    clearQueue();
    try enqueue("after the reply", false);
    try expect(try r.feed(done1));
    try std.testing.expectEqual(@as(usize, 0), r.sock.frames);
    try expectQueue(&.{"after the reply"}); // the step boundary delivers it
}

test "a stream that dies hands every steer back, in order, ahead of later follow-ups" {
    clearQueue();
    defer clearQueue();
    var r: Run = undefined;
    try r.start("gpt-6-sol");
    defer r.end();

    try enqueue("first", false);
    try enqueue("second", false);
    try expect(!try r.feed(created1));
    try expect(!try r.feed(accepted));
    try expect(!try r.feed(accepted));
    try expect(!try r.feed(bees));
    try expect(!try r.feed(done1));
    try expect(!try r.feed(created2)); // both placed in a body that now gets dropped
    try enqueue("typed later", false);
    r.st.settle(std.testing.allocator); // a stall or drop: postResponsesWs returns an error
    try expectQueue(&.{ "first", "second", "typed later" });
}

test "steering is GPT-6 on Codex, Platform OpenAI and the ChatGPT plan route; everything else ends on the terminal event" {
    try expect(steer.active("codex", "gpt-6-sol"));
    try expect(steer.active("openai", "gpt-6-astra"));
    try expect(steer.active("chatgpt-new", "gpt-6.1-sol"));
    try expect(!steer.active("codegraff", "gpt-6-sol"));
    try expect(!steer.active("codex", "gpt-5.6-sol"));

    clearQueue();
    defer clearQueue();
    var r: Run = undefined;
    try r.start("gpt-5.6-sol");
    defer r.end();
    try enqueue("queued", false);
    try expect(!try r.feed(created1));
    try expect(try r.feed(done1));
    try std.testing.expectEqual(@as(usize, 0), r.sock.frames);
}

test "a GPT-6 root turn leaves server compaction off until the context nears its threshold, then stops steering" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = try @import("agent_request_body_responses.zig").testAgentFor(arena_state.allocator(), "codex", .responses, "gpt-6-sol");
    const sc = @import("agent_server_compact.zig");
    const threshold = agent.provider.compactAt();

    try expect(sc.directive(&agent) == null); // inert this far below it anyway
    try expect(steer.steers(&agent));
    agent.last_context_tokens = threshold - threshold / 4 - 1;
    try expect(steer.steers(&agent));
    agent.last_context_tokens = threshold - threshold / 4; // compaction wins from here
    try std.testing.expectEqual(threshold, sc.directive(&agent).?);
    try expect(!steer.steers(&agent));

    // Requests nobody steers keep the directive at any size.
    agent.last_context_tokens = 0;
    agent.compaction_request = true;
    try std.testing.expectEqual(threshold, sc.directive(&agent).?);
    agent.compaction_request = false;
    agent.server_compaction_request = true;
    try std.testing.expectEqual(@as(u64, 1_000), sc.directive(&agent).?);
    agent.server_compaction_request = false;
    agent.provider.model = "gpt-5.6-sol";
    try std.testing.expectEqual(threshold, sc.directive(&agent).?);
}
