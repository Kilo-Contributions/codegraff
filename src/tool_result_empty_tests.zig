//! An empty tool result never reaches a wire as an empty string. A hosted
//! chat route turned "" into an empty text part, its upstream rejected the
//! request, and every later request in that conversation failed the same way.
const std = @import("std");
const messages = @import("messages.zig");

test "an empty tool result reads as the shell's marker on every wire" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_]@import("provider.zig").Provider.Kind{ .openai, .anthropic, .responses, .interactions }) |kind| {
        const msg = try messages.toolResultMessage(a, kind, "c1", "", false);
        const json = try std.json.Stringify.valueAlloc(a, msg, .{});
        try std.testing.expect(std.mem.indexOf(u8, json, messages.empty_result) != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"\"") == null);
    }
    const err = try messages.toolResultMessage(a, .openai, "c1", "", true);
    try std.testing.expectEqualStrings("[error] (no output)", err.object.get("content").?.string);
    const kept = try messages.toolResultMessage(a, .openai, "c1", "x", false);
    try std.testing.expectEqualStrings("x", kept.object.get("content").?.string);
}
