//! ADR 0232: what a spawned child inherits from the agent that started it,
//! the way the codex route's own client forks a child thread. The child keeps
//! its own prompt, tools and seat; it gains the user's request and its
//! parent's live reasoning effort.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ReasoningEffort = @import("main.zig").ReasoningEffort;
const Provider = @import("provider.zig").Provider;

/// The user's prompts a child sees, newest kept when the history runs over.
pub const task_cap = 8 * 1024;

/// The user's own prompts in the parent's history, oldest first, joined by a
/// rule. Harness notices and tool results are not prompts (userPromptText).
/// Past `task_cap` the oldest prompts drop and the newest one is cut from the
/// front, so the child always sees the request it was started for.
pub fn task(gpa: Allocator, messages: []const Value) ![]u8 {
    const sep = "\n\n---\n\n";
    var keep: usize = messages.len;
    var total: usize = 0;
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const text = @import("messages.zig").userPromptText(messages[i]) orelse continue;
        if (total > 0 and total + sep.len + text.len > task_cap) break;
        total += (if (total > 0) sep.len else 0) + text.len;
        keep = i;
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var first = true;
    for (messages[keep..]) |msg| {
        const text = @import("messages.zig").userPromptText(msg) orelse continue;
        if (!first) try out.writer.writeAll(sep);
        first = false;
        try out.writer.writeAll(if (text.len > task_cap) text[text.len - task_cap ..] else text);
    }
    return out.toOwnedSlice();
}

/// The child's first message: the user's request as context, then its own
/// task. Siblings share the context block, so it leads and their cached
/// prefix runs through it.
pub fn firstMessage(arena: Allocator, parent_task: []const u8, task_prompt: []const u8) ![]const u8 {
    if (parent_task.len == 0) return task_prompt;
    return std.fmt.allocPrint(arena, "The user's request to the agent that started you, for context only; do just your task below.\n\n{s}\n\nYour task:\n{s}", .{ parent_task, task_prompt });
}

/// The child's reasoning effort. A spawn or persona pin wins; otherwise the
/// child runs at its parent's live effort (the session's, as /effort or Jev
/// set it), when the child's own model accepts that level. null keeps the
/// worker default.
pub fn effort(parent: ?ReasoningEffort, pinned: ?ReasoningEffort, child: Provider) ?ReasoningEffort {
    if (pinned) |e| return e;
    const e = parent orelse return null;
    if (!@import("effort_route.zig").allows(child.id, child.model, @tagName(e))) return null;
    return e;
}

test "fork: the child sees the user's prompts, not notices or tool results (ADR 0232)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const messages = @import("messages.zig");
    var notice = try messages.textMessage(a, "user", "Already loaded for this turn: subagent.");
    try notice.object.put(a, @import("session_wake.zig").origin_key, .{ .string = "notification" });
    const history = [_]Value{
        try messages.textMessage(a, "user", "fix the parser"),
        try messages.textMessage(a, "assistant", "done"),
        notice,
        try messages.textMessage(a, "user", "now split the docs across sub-agents"),
    };
    const text = try task(gpa, &history);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("fix the parser\n\n---\n\nnow split the docs across sub-agents", text);

    const first = try firstMessage(a, text, "write docs/FORMAT.md");
    try std.testing.expect(std.mem.startsWith(u8, first, "The user's request to the agent that started you"));
    try std.testing.expect(std.mem.endsWith(u8, first, "Your task:\nwrite docs/FORMAT.md"));
    try std.testing.expectEqualStrings("write docs/FORMAT.md", try firstMessage(a, "", "write docs/FORMAT.md"));
}

test "fork: the newest prompt survives the cap" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const messages = @import("messages.zig");
    const old = try a.alloc(u8, task_cap);
    @memset(old, 'o');
    const history = [_]Value{ try messages.textMessage(a, "user", old), try messages.textMessage(a, "user", "the request") };
    const text = try task(gpa, &history);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("the request", text);
}

test "fork: a pin wins, else the parent's effort when the child's model takes it" {
    const sol: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-sol", .context = 1 };
    try std.testing.expectEqual(ReasoningEffort.low, effort(.high, .low, sol).?);
    try std.testing.expectEqual(ReasoningEffort.high, effort(.high, null, sol).?);
    try std.testing.expect(effort(null, null, sol) == null);
}
