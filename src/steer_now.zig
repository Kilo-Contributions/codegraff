//! Act on a new message mid-reply. A follow-up the user sends while the model
//! is still streaming supersedes that reply: the stream is cut, the partial
//! answer (never committed to history) is dropped, and the request is rebuilt
//! with the follow-up appended. Tools that are already running finish first,
//! and the follow-up then lands at the next step boundary as before.
//!
//! GPT-6 over the Responses WebSocket keeps its server-side `response.steer`
//! (agent_ws_steer.zig), so the WebSocket path supersedes only models without
//! it. Follow-ups reach this queue from the line REPL's stdin scan and from
//! the TUI (tui_launch's steer hand-off).

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");
const repl_glue = @import("repl_glue.zig");

/// A soft follow-up is waiting, and this request is the root's own turn
/// request (not compaction, a title, a judge or a child), so it may be
/// superseded. A force follow-up interrupts the turn instead.
pub fn pending(self: *const Agent) bool {
    if (self.sub or self.call_kind != .root or self.compaction_request) return false;
    // Early-started tools (ADR 0177) own this stream's results; let it finish.
    if (@import("agent_async_tools.zig").started(self)) return false;
    return queued();
}

/// The head of the follow-up queue is a soft one.
pub fn queued() bool {
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    const q = &main_mod.g_steer_queue;
    return q.items.len > 0 and !q.items[0].force;
}

/// The stream was cut for a follow-up: hand it (and anything else waiting)
/// to the conversation and rebuild the request. Always true: the caller
/// rebuilds even when delivery found nothing left to add.
pub fn supersede(self: *Agent) bool {
    self.partial_text.clearRetainingCapacity(); // the fresh stream restarts the reply, no concat
    @import("turn_inbox.zig").deliver(self) catch {};
    self.closeCodexWs(); // a codex WS chain is keyed on the abandoned response
    if (self.tracer) |t| t.note("steer", "a follow-up superseded the streaming reply; request rebuilt");
    return true;
}

/// The TUI hands a mid-turn follow-up to the running turn. Page-allocated,
/// like the line REPL's entries (turn_inbox frees them the same way).
pub fn send(text: []const u8) bool {
    const owned = std.heap.page_allocator.dupe(u8, text) catch return false;
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    main_mod.g_steer_queue.append(std.heap.page_allocator, .{ .text = owned, .force = false }) catch {
        std.heap.page_allocator.free(owned);
        return false;
    };
    return true;
}

/// Put follow-ups back at the head of the queue, in order: a steer the server
/// rejected, or one a failed stream never delivered (agent_ws_steer). Takes
/// the page-allocated texts; one the queue cannot hold is dropped.
pub fn requeue(texts: []const []const u8) void {
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    var at: usize = 0;
    for (texts) |t| {
        main_mod.g_steer_queue.insert(std.heap.page_allocator, at, .{ .text = t, .force = false }) catch {
            std.heap.page_allocator.free(t);
            continue;
        };
        at += 1;
    }
}

/// Soft follow-ups the finished turn never delivered (they arrived after its
/// last reply), moved out for the frontend to run as the next turn. Force
/// entries stay for the interrupt path.
pub fn reclaim(gpa: std.mem.Allocator, out: *std.array_list.Managed([]const u8)) void {
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    const q = &main_mod.g_steer_queue;
    var i: usize = 0;
    while (i < q.items.len) {
        const e = q.items[i];
        if (e.force) {
            i += 1;
            continue;
        }
        const copy = gpa.dupe(u8, e.text) catch {
            i += 1;
            continue;
        };
        out.append(copy) catch {
            gpa.free(copy);
            i += 1;
            continue;
        };
        std.heap.page_allocator.free(e.text);
        _ = q.orderedRemove(i);
    }
}

fn clearQueue() void {
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    for (main_mod.g_steer_queue.items) |e| std.heap.page_allocator.free(e.text);
    main_mod.g_steer_queue.clearRetainingCapacity();
}

test "only a soft follow-up at the head supersedes a root turn request" {
    clearQueue();
    defer clearQueue();
    var root: Agent = undefined;
    root.sub = false;
    root.call_kind = .root;
    root.compaction_request = false;
    root.async_tools = null;
    try std.testing.expect(!pending(&root));

    try std.testing.expect(send("also run the tests"));
    try std.testing.expect(pending(&root));
    root.compaction_request = true; // the summary call is not the user's reply
    try std.testing.expect(!pending(&root));
    root.compaction_request = false;
    root.call_kind = .title;
    try std.testing.expect(!pending(&root));
    root.call_kind = .root;
    root.sub = true;
    try std.testing.expect(!pending(&root));
    root.sub = false;

    clearQueue();
    const force = try std.heap.page_allocator.dupe(u8, "stop");
    repl_glue.steerLock();
    try main_mod.g_steer_queue.append(std.heap.page_allocator, .{ .text = force, .force = true });
    repl_glue.steerUnlock();
    try std.testing.expect(!pending(&root)); // force interrupts; it never rebuilds
}

test "reclaim moves undelivered soft follow-ups out and leaves force behind" {
    clearQueue();
    defer clearQueue();
    try std.testing.expect(send("first"));
    const force = try std.heap.page_allocator.dupe(u8, "stop");
    repl_glue.steerLock();
    try main_mod.g_steer_queue.append(std.heap.page_allocator, .{ .text = force, .force = true });
    repl_glue.steerUnlock();
    try std.testing.expect(send("second"));

    var out = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer {
        for (out.items) |t| std.testing.allocator.free(t);
        out.deinit();
    }
    reclaim(std.testing.allocator, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("first", out.items[0]);
    try std.testing.expectEqualStrings("second", out.items[1]);
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    try std.testing.expectEqual(@as(usize, 1), main_mod.g_steer_queue.items.len);
    try std.testing.expect(main_mod.g_steer_queue.items[0].force);
}
