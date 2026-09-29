//! A safety refusal from a Claude model (`stop_reason: "refusal"`, with the
//! category in `stop_details`). The turn ends there: the refused reply stays
//! out of history, as Anthropic advises for the turn that drew a refusal
//! (dropping the end of history is not a prefix edit), and the turn never
//! reads as an empty reply, which the retry path would send again (ADR 0219).

const std = @import("std");

/// The `stop_details.category` of a response root, if it names one.
pub fn category(root: std.json.ObjectMap) ?[]const u8 {
    const d = root.get("stop_details") orelse return null;
    if (d != .object) return null;
    const c = d.object.get("category") orelse return null;
    return if (c == .string and c.string.len > 0) c.string else null;
}

/// What the turn ends with, for the user and for a parent agent.
pub fn text(a: std.mem.Allocator, cat: ?[]const u8) ![]u8 {
    if (cat) |c| return std.fmt.allocPrint(a, "[the model declined this request (safety category: {s}); graff did not retry it. Rephrase the request, or switch models with /model]", .{c});
    return a.dupe(u8, "[the model declined this request; graff did not retry it. Rephrase the request, or switch models with /model]");
}

test "the refusal line names the category when there is one" {
    const a = std.testing.allocator;
    const with = try text(a, "bio");
    defer a.free(with);
    try std.testing.expect(std.mem.indexOf(u8, with, "safety category: bio") != null);
    const without = try text(a, null);
    defer a.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "declined") != null);
}
