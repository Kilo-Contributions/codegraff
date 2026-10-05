//! Explicit non-completing turn boundary for missing user input (#1531).
//! No question/confirmation, verifier bypass claim, or durable goal transition.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const tools = @import("tools.zig");

pub const tool_name = "yield_turn";
pub const spec: @import("schema.zig").ToolSpec = .{
    .name = tool_name,
    .desc = "End the current turn without completing the task or closing the conversation. Call alone after finishing independent authorized work when you need input on the user's next prompt, especially a screenshot that a question dialog cannot accept, or when the user asks to stop. Put the explanation and needed next-prompt input in message. No permission to pause is required. Stops open-work retries and autonomous continuation even with unfinished todos or an unmet verifier; preserves goals, checklist statuses, and verification state. Never use attempt_completion or mark unfinished work done for this handoff.",
    .schema =
    \\{"type": "object", "properties": {"message": {"type": "string", "description": "Explain why this turn is stopping and what input is needed on the next prompt"}}, "required": ["message"]}
    ,
};

pub fn rejectMixedBatch(self: *Agent, calls: []const tools.ToolCall, results: []tools.ExecResult) !bool {
    if (calls.len <= 1) return false;
    for (calls) |call| if (std.mem.eql(u8, call.name, tool_name)) {
        const text = "yield_turn must run alone; this batch was rejected";
        for (calls, results) |c, *r| {
            self.emitToolRejected(c, "handoff_boundary", text);
            r.* = .{ .text = text, .is_error = true };
        }
        return true;
    };
    return false;
}

pub fn handle(self: *Agent, call: tools.ToolCall) !tools.ExecResult {
    if (self.sub) return .{ .text = "yield_turn is root-only; return your blocker to the parent", .is_error = true };
    const obj = tools.json_args.object(call.input) orelse return invalid();
    const raw = tools.json_args.str(obj, "message") orelse return invalid();
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return invalid();
    const message = try @import("cite_markup.zig").dupe(self.arena, raw);
    if (@import("main.zig").json_mode) {
        self.emit(.{ .type = "text", .text = message });
    } else try self.say("{s}\n", .{message});
    self.yielded = message;
    @import("peer_idle.zig").noteHandoff();
    return .{ .text = "turn yielded; task remains unfinished and conversation stays open", .is_error = false };
}

fn invalid() tools.ExecResult {
    return .{ .text = "yield_turn requires a nonempty message explaining the handoff", .is_error = true };
}
