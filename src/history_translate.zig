//! History translation across a /model switch that changes wire format.
//! Split out of providers.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Provider = @import("provider.zig").Provider;
const extractText = @import("providers.zig").extractText;
const textMessage = @import("messages.zig").textMessage;
const hot_context = @import("hot_context.zig");

/// Rebuild the history as text-only user/assistant turns in `to_kind`'s format
/// — used to carry the conversation across a wire-format switch. Tool-call
/// structure is dropped (the dialogue is what matters for continuity).
/// textMessage's {role,content:string} shape is valid in all 3 formats.
/// Hot-context updates may be developer/system-role, so they are retyped for
/// the new wire rather than dropped; otherwise the model would fall back to
/// the stale instructions in the system prompt.
pub fn translateHistory(arena: Allocator, msgs: *std.json.Array, to_kind: Provider.Kind) void {
    var out = std.json.Array.init(arena);
    for (msgs.items) |m| {
        if (m != .object) continue;
        if (hot_context.isHotContext(m)) {
            out.append(hot_context.retyped(arena, to_kind, extractText(arena, m)) catch continue) catch {};
            continue;
        }
        const role = if (m.object.get("role")) |r| (if (r == .string) r.string else "") else "";
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) continue;
        const text = std.mem.trim(u8, extractText(arena, m), " \t\r\n");
        if (text.len == 0) continue;
        out.append(@import("session_wake.zig").copyOrigin(arena, m, textMessage(arena, role, text) catch continue) catch continue) catch {};
    }
    msgs.* = out;
}

fn parse(a: Allocator, s: []const u8) Value {
    return std.json.parseFromSliceLeaky(Value, a, s, .{}) catch unreachable;
}

test "translateHistory: flattens to {role,content:string}, keeps user/assistant, drops the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(parse(a, "{\"role\":\"system\",\"content\":\"sys\"}")); // dropped
    try msgs.append(parse(a, "{\"role\":\"user\",\"content\":\"hello\"}")); // kept
    try msgs.append(parse(a, "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}")); // flattened
    try msgs.append(parse(a, "{\"role\":\"tool\",\"content\":\"result\"}")); // dropped
    try msgs.append(parse(a, "{\"role\":\"user\",\"content\":\"   \"}")); // whitespace-only -> dropped
    translateHistory(a, &msgs, .anthropic);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("user", msgs.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("hello", msgs.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("assistant", msgs.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("hi", msgs.items[1].object.get("content").?.string);
}

test "translateHistory retypes a hot-context update for the new wire" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(parse(a, "{\"role\":\"user\",\"content\":\"hi\"}"));
    try msgs.append(try hot_context.retyped(a, .responses, "<context key=\"core/date\">x</context>"));
    try std.testing.expectEqualStrings("developer", msgs.items[1].object.get("role").?.string);
    translateHistory(a, &msgs, .anthropic);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expect(hot_context.isHotContext(msgs.items[1]));
    try std.testing.expectEqualStrings("user", msgs.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("<context key=\"core/date\">x</context>", msgs.items[1].object.get("content").?.string);
}
