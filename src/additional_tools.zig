//! Deferred tools loaded without touching `tools` (ADR 0221), the way OpenAI's
//! prompt-caching guide asks.
//!
//! The stable catalog (ADR 0011) appends each loaded tool to the END of the
//! `tools` array. OpenAI renders tools ahead of every message and checks cache
//! breakpoints only at message ends, so any change to `tools` makes the whole
//! conversation miss the cache on the next request. Codex hides that tail
//! behind hosted tool search (`defer_loading`), which the ChatGPT plan's new
//! sign-in refuses. OpenAI's documented alternative is a developer-role
//! `additional_tools` input item: it adds the loaded definitions where the
//! load happened, after the prefix it would otherwise invalidate.
//!
//! MiMo's chat wire is worse off: it renders `tools` ahead of the system
//! prompt, so one appended tool re-bills the whole prompt (a probe that
//! appended one went from a full cache hit to none). It has no such item, but
//! it calls a tool announced in a system message. Its parser types arguments
//! only for declared tools, so tool_call_repair.retypeArgs restores the
//! announced tools' argument types.
//!
//! So on these routes the tail never reaches `tools`, and before each request
//! `sync` announces every loaded tool that no announcement in the history
//! carries yet: once per tool, and again only if compaction pruned it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Io = std.Io;

const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const mcp = @import("mcp.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const native_fold = @import("native_fold.zig");
const origin_key = @import("session_wake.zig").origin_key;

pub const item_type = "additional_tools";
const chat_header = "Additional tools are now available. Call them exactly like the tools in your tool list:\n<tools>\n";

/// Routes that load deferred tools through announcements instead of `tools`.
pub fn active(p: Provider) bool {
    if (!mcp_schema_gate.g_stable_catalog) return false;
    return switch (p.kind) {
        .responses => std.mem.eql(u8, p.id, "chatgpt-new"),
        .openai => @import("effort_route.zig").mimoRoute(p.id, p.model),
        .anthropic, .interactions => false,
    };
}

/// The loaded tail as tool entries for the agent's wire: exactly what the
/// stable catalog would append to `tools`.
fn tailEntries(self: *Agent, arena: Allocator) ![]const Value {
    const connected: []const mcp.Tool = if (self.registry) |reg| try reg.snapshotTools(arena) else &.{};
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginArray();
    try native_fold.renderLoadedTail(&s, self.provider.kind, arena, connected);
    try s.endArray();
    const v = try std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always });
    return if (v == .array) v.array.items else &.{};
}

/// A tool entry's name; chat entries nest it under `function`.
fn toolName(tool: Value) []const u8 {
    if (tool != .object) return "";
    const f = tool.object.get("function") orelse tool;
    if (f != .object) return "";
    const n = f.object.get("name") orelse return "";
    return if (n == .string) n.string else "";
}

/// A Responses `additional_tools` item, or a chat announcement (tagged by origin).
pub fn isItem(m: Value) bool {
    if (m != .object) return false;
    const t = m.object.get("type") orelse m.object.get(origin_key) orelse return false;
    return t == .string and std.mem.eql(u8, t.string, item_type);
}

fn announced(arena: Allocator, messages: []const Value, name: []const u8) bool {
    for (messages) |m| if (isItem(m)) {
        if (m.object.get("tools")) |list| if (list == .array) {
            for (list.array.items) |t| if (std.mem.eql(u8, toolName(t), name)) return true;
        };
        // A chat announcement carries one definition per line.
        const c = m.object.get("content") orelse continue;
        if (c != .string) continue;
        var lines = std.mem.splitScalar(u8, c.string, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "{")) continue;
            const t = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch continue;
            if (std.mem.eql(u8, toolName(t), name)) return true;
        }
    };
    return false;
}

fn inTail(tail: []const Value, name: []const u8) bool {
    for (tail) |t| if (std.mem.eql(u8, toolName(t), name)) return true;
    return false;
}

/// Before a request: announce each loaded tool the history does not carry yet.
/// On any other route, remove the announcements instead. Other wires do not
/// know them, and there the catalog tail carries the loaded tools.
pub fn sync(self: *Agent) void {
    if (self.sub) return;
    if (!active(self.provider)) return dropItems(&self.messages);
    const arena = self.messageMutationAlloc();
    const tail = tailEntries(self, arena) catch return;
    var fresh = std.json.Array.init(arena);
    for (tail) |t| if (!announced(arena, self.messages.items, toolName(t))) fresh.append(t) catch return;
    if (fresh.items.len == 0) return;
    const item = announcement(arena, self.provider.kind, fresh) catch return;
    self.messages.append(item) catch {};
}

/// A developer-role `additional_tools` item on Responses. The chat wire has no
/// such item, so there it is a system message with one definition per line.
fn announcement(arena: Allocator, kind: Provider.Kind, tools: std.json.Array) !Value {
    var item: std.json.ObjectMap = .empty;
    if (kind == .responses) {
        try item.put(arena, "type", .{ .string = item_type });
        try item.put(arena, "role", .{ .string = "developer" });
        try item.put(arena, "tools", .{ .array = tools });
        return .{ .object = item };
    }
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll(chat_header);
    for (tools.items) |t| try aw.writer.print("{s}\n", .{try std.json.Stringify.valueAlloc(arena, t, .{})});
    try aw.writer.writeAll("</tools>");
    try item.put(arena, "role", .{ .string = "system" });
    try item.put(arena, "content", .{ .string = aw.writer.buffered() });
    try item.put(arena, origin_key, .{ .string = item_type });
    return .{ .object = item };
}

fn dropItems(messages: *std.json.Array) void {
    var i: usize = 0;
    while (i < messages.items.len) {
        if (isItem(messages.items[i])) _ = messages.orderedRemove(i) else i += 1;
    }
}

/// The request's `tools` without the loaded tail. Always re-serialized on these
/// routes, even with nothing loaded, so the bytes stay identical from the first
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
