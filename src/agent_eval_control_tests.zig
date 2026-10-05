//! Enforceable predict -> verify -> repair controller tests.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const agent_tools = @import("agent_tools.zig");
const eval_control = @import("agent_eval_control.zig");
const repl_glue = @import("repl_glue.zig");
const ToolCall = @import("tools.zig").ToolCall;

fn call(arena: std.mem.Allocator, name: []const u8, input: []const u8) !ToolCall {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{});
    return .{ .id = "control-test", .name = name, .input = value };
}

test "attempt_completion is blocked until the latest verifier result is green" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = true,
        .label = "test",
        .out = null,
        .eval_cmd = "verify",
    };
    const completion = try call(arena, "attempt_completion", "{\"result\":\"done\"}");

    const unverified = try agent.handleMeta(completion);
    try std.testing.expect(unverified.is_error);
    try std.testing.expect(agent.completed == null);

    agent.eval_verified = true;
    agent.eval_repair_pending = true;
    const red = try agent.handleMeta(completion);
    try std.testing.expect(red.is_error);
    try std.testing.expect(agent.completed == null);

    agent.eval_repair_pending = false;
    const green = try agent.handleMeta(completion);
    try std.testing.expect(!green.is_error);
    try std.testing.expectEqualStrings("done", agent.completed.?);
}

test "workspace-changing tools stale verification while read-only tools do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(agent_tools.toolInvalidatesEval(try call(arena, "edit_file", "{}")));
    try std.testing.expect(agent_tools.toolInvalidatesEval(try call(arena, "bash", "{}")));
    try std.testing.expect(agent_tools.toolInvalidatesEval(try call(arena, "subagent", "{}")));
    try std.testing.expect(!agent_tools.toolInvalidatesEval(try call(arena, "read_file", "{}")));
    try std.testing.expect(!agent_tools.toolInvalidatesEval(try call(arena, "codedb", "{}")));
    try std.testing.expect(!agent_tools.toolInvalidatesEval(try call(arena, "mcp__codedbpro__read", "{}")));
    try std.testing.expect(agent_tools.toolInvalidatesEval(try call(arena, "mcp__codedbpro__edit", "{}")));
}

test "verify bash does not block same-batch attempt_completion; edit/rlm still do" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bash_done = [_]ToolCall{
        try call(arena, "bash", "{}"),
        try call(arena, "attempt_completion", "{\"result\":\"done\"}"),
    };
    try std.testing.expect(!eval_control.batchBlocksCompletion(&bash_done));
    try std.testing.expect(eval_control.shouldDeferCompletion(&bash_done));
    try std.testing.expectEqual(@as(?usize, 1), eval_control.completionIndex(&bash_done));

    const read_done = [_]ToolCall{
        try call(arena, "codedb", "{}"),
        try call(arena, "attempt_completion", "{\"result\":\"done\"}"),
    };
    try std.testing.expect(eval_control.shouldDeferCompletion(&read_done));

    const edit_done = [_]ToolCall{
        try call(arena, "edit_file", "{}"),
        try call(arena, "attempt_completion", "{\"result\":\"done\"}"),
    };
    try std.testing.expect(eval_control.batchBlocksCompletion(&edit_done));
    try std.testing.expect(!eval_control.shouldDeferCompletion(&edit_done));

    const rlm_done = [_]ToolCall{
        try call(arena, "rlm", "{}"),
        try call(arena, "attempt_completion", "{\"result\":\"done\"}"),
    };
    try std.testing.expect(eval_control.batchBlocksCompletion(&rlm_done));
    try std.testing.expect(!eval_control.shouldDeferCompletion(&rlm_done));

    const only_done = [_]ToolCall{try call(arena, "attempt_completion", "{\"result\":\"done\"}")};
    try std.testing.expect(!eval_control.shouldDeferCompletion(&only_done));
}

test "eval is a solo verifier boundary in a tool batch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls = [_]ToolCall{
        try call(arena, "edit_file", "{}"),
        try call(arena, "eval", "{}"),
        try call(arena, "read_file", "{}"),
    };
    try std.testing.expectEqual(@as(?usize, 1), eval_control.evalCallIndex(&calls));
    try std.testing.expectEqualStrings(
        "eval is a verifier boundary and must run alone; this tool was not executed",
        eval_control.verifier_boundary,
    );
    try std.testing.expect(eval_control.shouldStopAfterBatch(&calls, true));
    try std.testing.expect(!eval_control.shouldStopAfterBatch(&calls, false));

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = true,
        .label = "test",
        .out = &output.writer,
    };
    const results = try agent.runTools(&calls);
    try std.testing.expect(results[0].is_error);
    try std.testing.expectEqualStrings(eval_control.verifier_boundary, results[0].text);
    try std.testing.expect(results[1].is_error);
    try std.testing.expect(std.mem.indexOf(u8, results[1].text, "no eval command configured") != null);
    try std.testing.expect(results[2].is_error);
    try std.testing.expectEqualStrings(eval_control.verifier_boundary, results[2].text);
}

test "eval steering carries controller state and local belief memory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const note = try repl_glue.evalSteeringNote(
        arena_state.allocator(),
        "verify",
        90,
        false,
        true,
        true,
        "## CONFIRMED\n- compiler failed",
    );
    try std.testing.expect(std.mem.indexOf(u8, note, "Verifier state: RED") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "prior plan is dropped") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "compiler failed") != null);
}

test "read-only MCP never hides a later mutation from completion policy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const read = try call(arena, "mcp__codedbpro__read", "{}");
    const done = try call(arena, "attempt_completion", "{\"result\":\"done\"}");
    for ([_][]const u8{ "edit_file", "write_file", "rlm", "subagent", "mcp__codedbpro__edit" }) |name| {
        const mutation = try call(arena, name, "{}");
        const orders = [_][3]ToolCall{
            .{ read, mutation, done }, .{ read, done, mutation },
            .{ mutation, read, done }, .{ mutation, done, read },
            .{ done, read, mutation }, .{ done, mutation, read },
        };
        for (orders) |batch| {
            try std.testing.expect(eval_control.batchBlocksCompletion(&batch));
            try std.testing.expect(!eval_control.shouldDeferCompletion(&batch));
        }
    }
    for ([_][2]ToolCall{ .{ read, done }, .{ done, read } }) |batch| {
        try std.testing.expect(!eval_control.batchBlocksCompletion(&batch));
        try std.testing.expect(eval_control.shouldDeferCompletion(&batch));
    }
}

fn handoffFixture(arena: std.mem.Allocator) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 128000 },
        .messages = .init(arena),
        .sub = false,
        .label = "test",
        .out = null,
        .eval_cmd = "verify",
        .eval_repair_pending = true,
        .goal = .{ .objective = "fix the control", .standing = true, .epoch = 1 },
    };
}

test "yield_turn (#1531): stops without verifier, completion, or pause approval and preserves work" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = handoffFixture(arena);
    try agent.todos.append(arena, .{ .content = "fix the control", .status = "in_progress", .epoch = 1 });
    const handoff = try call(arena, "yield_turn", "{\"message\":\"Stopping this turn; attach the screenshot to your next prompt.\"}");
    const saved_max = @import("main.zig").max_tool_calls;
    defer @import("main.zig").max_tool_calls = saved_max;
    const idle = @import("peer_idle.zig");
    const was_suppressed = idle.idleWakeSuppressed();
    const was_waiting = idle.waitingForInput();
    defer {
        idle.noteHumanPrompt();
        if (was_suppressed) idle.noteCompletion();
        if (was_waiting) idle.noteHandoff();
    }
    const saved_json = @import("main.zig").json_mode;
    @import("main.zig").json_mode = false;
    defer @import("main.zig").json_mode = saved_json;
    var output: std.Io.Writer.Allocating = .init(arena);
    agent.out = &output.writer;
    agent.streamed_text = true; // a preamble must not hide the handoff explanation

    @import("main.zig").max_tool_calls = 0;
    try std.testing.expect((try agent_tools.rejectToolCall(&agent, handoff)) == null);
    const result = try agent.handleMeta(handoff);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "attach the screenshot") != null);
    try std.testing.expect(idle.idleWakeSuppressed());
    const notify = @import("job_notify.zig");
    var wake_buf: [512]u8 = undefined;
    while (notify.takeIdleWake(agent.io, &wake_buf)) |_| {}
    notify.record(agent.io, 1531, 0, false, "handoff-fixture", false);
    try std.testing.expect(@import("idle_wake_sources.zig").takeIdleWake(agent.io, "handoff-fixture", &wake_buf) == null);
    try std.testing.expect(notify.pending(agent.io));
    idle.noteHumanPrompt();
    try std.testing.expect(!idle.idleWakeSuppressed() and !idle.waitingForInput());
    try std.testing.expect(notify.takeIdleWake(agent.io, &wake_buf) != null);
    try std.testing.expectEqualStrings("Stopping this turn; attach the screenshot to your next prompt.", agent.yielded.?);
    try std.testing.expect(agent.completed == null);
    try std.testing.expect(!agent.completion_refused);
    try std.testing.expect(!agent.completion_gate_armed);
    try std.testing.expect(agent.eval_repair_pending and !agent.eval_verified);
    try std.testing.expectEqual(@import("agent.zig").GoalStatus.active, agent.goal.?.status);
    try std.testing.expectEqualStrings("in_progress", agent.todos.items[0].status);
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.blocked, @import("goal_flow.zig").loopTurnDecision(&agent, 25, 0).stop);
}

test "yield_turn (#1531): malformed or child handoffs do not end execution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = handoffFixture(arena);
    for ([_][]const u8{ "{}", "{\"message\":1}", "{\"message\":\" \\n\"}" }) |input| {
        try std.testing.expect((try agent.handleMeta(try call(arena, "yield_turn", input))).is_error);
        try std.testing.expect(agent.yielded == null);
    }
    agent.sub = true;
    try std.testing.expect((try agent.handleMeta(try call(arena, "yield_turn", "{\"message\":\"wait\"}"))).is_error);
    try std.testing.expect(agent.yielded == null);
}

test "yield_turn (#1531): mixed batches execute nothing instead of racing the handoff" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = handoffFixture(arena);
    const batch = [_]ToolCall{
        try call(arena, "yield_turn", "{\"message\":\"wait\"}"),
        try call(arena, "todo_write", "{\"todos\":[{\"content\":\"should not run\",\"status\":\"completed\"}]}"),
    };
    const results = try agent.runTools(&batch);
    for (results) |result| try std.testing.expect(result.is_error);
    try std.testing.expect(agent.yielded == null);
    try std.testing.expectEqual(@as(usize, 0), agent.todos.items.len);
}
