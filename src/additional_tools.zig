//! Deferred tools on the ChatGPT plan's new sign-in (ADR 0221), loaded the way
//! OpenAI's prompt-caching guide asks: without touching `tools`.
//!
//! The stable catalog (ADR 0011) appends each loaded tool to the END of the
//! `tools` array. OpenAI renders tools ahead of every message and checks cache
//! breakpoints only at message ends, so any change to `tools` makes the whole
//! conversation miss the cache on the next request. Codex hides that tail
//! behind hosted tool search (`defer_loading`), which this route refuses.
//! OpenAI's documented alternative is a developer-role `additional_tools`
//! input item: it adds the loaded definitions where the load happened, after
//! the prefix it would otherwise invalidate.
//!
//! So on this route the tail never reaches `tools`, and before each request
//! `sync` announces every loaded tool that no `additional_tools` item in the
//! history carries yet: once per tool, and again only if compaction pruned
//! the item that carried it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Io = std.Io;

const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const mcp = @import("mcp.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const native_fold = @import("native_fold.zig");

pub const item_type = "additional_tools";

/// Routes that load deferred tools through `additional_tools` items.
pub fn active(provider_id: []const u8, kind: Provider.Kind) bool {
    return kind == .responses and std.mem.eql(u8, provider_id, "chatgpt-new") and mcp_schema_gate.g_stable_catalog;
}

/// The loaded tail as Responses tool entries: exactly what the stable catalog
/// would append to `tools`.
fn tailEntries(self: *Agent, arena: Allocator) ![]const Value {
    const connected: []const mcp.Tool = if (self.registry) |reg| try reg.snapshotTools(arena) else &.{};
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginArray();
    try native_fold.renderLoadedTail(&s, .responses, arena, connected);
    try s.endArray();
    const v = try std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
    return if (v == .array) v.array.items else &.{};
}

fn toolName(tool: Value) []const u8 {
    if (tool != .object) return "";
    const n = tool.object.get("name") orelse return "";
    return if (n == .string) n.string else "";
}

pub fn isItem(m: Value) bool {
    if (m != .object) return false;
    const t = m.object.get("type") orelse return false;
    return t == .string and std.mem.eql(u8, t.string, item_type);
}

fn announced(messages: []const Value, name: []const u8) bool {
    for (messages) |m| if (isItem(m)) if (m.object.get("tools")) |list| if (list == .array) {
        for (list.array.items) |t| if (std.mem.eql(u8, toolName(t), name)) return true;
    };
    return false;
}

fn inTail(tail: []const Value, name: []const u8) bool {
    for (tail) |t| if (std.mem.eql(u8, toolName(t), name)) return true;
    return false;
}

/// Before a request: announce each loaded tool the history does not carry yet.
/// On any other route, remove the items instead. Other wires do not know them,
/// and there the catalog tail carries the loaded tools.
pub fn sync(self: *Agent) void {
    if (self.sub) return;
    if (!active(self.provider.id, self.provider.kind)) return dropItems(&self.messages);
    const arena = self.messageMutationAlloc();
    const tail = tailEntries(self, arena) catch return;
    var fresh = std.json.Array.init(arena);
    for (tail) |t| if (!announced(self.messages.items, toolName(t))) fresh.append(t) catch return;
    if (fresh.items.len == 0) return;
    var item: std.json.ObjectMap = .empty;
    item.put(arena, "type", .{ .string = item_type }) catch return;
    item.put(arena, "role", .{ .string = "developer" }) catch return;
    item.put(arena, "tools", .{ .array = fresh }) catch return;
    self.messages.append(.{ .object = item }) catch {};
}

fn dropItems(messages: *std.json.Array) void {
    var i: usize = 0;
    while (i < messages.items.len) {
        if (isItem(messages.items[i])) _ = messages.orderedRemove(i) else i += 1;
    }
}

/// The request's `tools` without the loaded tail. Always re-serialized on this
/// route, even with nothing loaded, so the bytes stay identical from the first
/// request to the last.
pub fn stripTail(self: *Agent, arena: Allocator, tools_json: []const u8) []const u8 {
    const tail = tailEntries(self, arena) catch return tools_json;
    var v = std.json.parseFromSliceLeaky(Value, arena, tools_json, .{ .allocate = .alloc_always }) catch return tools_json;
    if (v != .array) return tools_json;
    var i: usize = 0;
    while (i < v.array.items.len) {
        const name = toolName(v.array.items[i]);
        if (name.len > 0 and inTail(tail, name)) _ = v.array.orderedRemove(i) else i += 1;
    }
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(v) catch return tools_json;
    return aw.writer.buffered();
}

test {
    _ = @import("additional_tools_tests.zig");
}
