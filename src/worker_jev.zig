//! ADR 0232: a child whose model Jev serves can ask Jev for its own effort
//! mid-run, as its root can. A child starts at its parent's live effort; Jev
//! can then move it for the child's next request. The selection is the
//! child's alone: the root's effort and the session's saved effort do not
//! change (jev_effort_state.apply).

const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("schema.zig");
const jev_tool = @import("jev_tool.zig");
const Provider = @import("provider.zig").Provider;
const Agent = @import("agent.zig").Agent;

/// subagent_run calls this as it builds a child, after worker_mcp.inherit:
/// whatever catalog the child would be served gains jev_effort while Jev is
/// available for the child's own seat.
pub fn offer(agent: *Agent) void {
    if (!jev_tool.available(agent.provider)) return;
    if (withJev(agent.arena, agent.provider.kind, agent.toolsJson())) |built| agent.worker_tools = built;
}

/// `base` (a JSON array of tool entries) plus the jev_effort entry. null when
/// the entry is already there or `base` is not an array. On Responses the
/// entry is eager, so hosted tool search leaves it callable (ADR 0231).
pub fn withJev(arena: Allocator, kind: Provider.Kind, base: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, base, "\"" ++ jev_tool.name ++ "\"") != null) return null;
    const head = std.mem.trimEnd(u8, base, " \t\r\n");
    if (head.len < 2 or head[0] != '[' or head[head.len - 1] != ']') return null;
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    const written = if (kind == .responses)
        schema.writeEagerResponsesEntry(&s, jev_tool.name, jev_tool.description, .{ .raw = jev_tool.input_schema })
    else
        schema.writeToolEntry(&s, kind, jev_tool.name, jev_tool.description, .{ .raw = jev_tool.input_schema });
    written catch return null;
    const entry = aw.writer.buffered();
    if (std.mem.trim(u8, head[1 .. head.len - 1], " \t\r\n").len == 0) return std.fmt.allocPrint(arena, "[{s}]", .{entry}) catch null;
    return std.fmt.allocPrint(arena, "{s},{s}]", .{ head[0 .. head.len - 1], entry }) catch null;
}

test "a child's catalog gains jev_effort once, eager on Responses (ADR 0232)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = "[{\"type\":\"function\",\"name\":\"shell\"}]";
    const out = withJev(a, .responses, base).?;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.array.items.len);
    try std.testing.expectEqualStrings(jev_tool.name, parsed.array.items[1].object.get("name").?.string);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"defer_loading\":false") != null);
    try std.testing.expect(withJev(a, .responses, out) == null); // already there
    const alone = withJev(a, .anthropic, "[]").?;
    const one = try std.json.parseFromSliceLeaky(std.json.Value, a, alone, .{});
    try std.testing.expectEqual(@as(usize, 1), one.array.items.len);
    try std.testing.expect(one.array.items[0].object.get("input_schema") != null);
    try std.testing.expect(withJev(a, .responses, "not a catalog") == null);
}

test "a child's Jev selection lands in its own pending slot, not its root's (ADR 0232)" {
    const state = @import("jev_effort_state.zig");
    jev_tool.configure(struct {
        pub fn get(_: @This(), key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "JEV_BACKEND")) "mock" else null;
        }
    }{});
    defer jev_tool.configure(struct {
        pub fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    }{});
    _ = jev_tool.setCodegraffLoginKey(std.testing.io, "synthetic-login");
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-sol", .context = 100_000 };
    var root_pending: state.Pending = .{};
    var child_pending: state.Pending = .{};
    var client: std.http.Client = undefined;
    const child: @import("tools.zig").ToolCtx = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .provider = p, .jev_effort_pending = &child_pending, .registry = null, .from_sub = true, .approvals = null, .tracer = null };
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"task\":\"count lines in four log folders\"}", .{});
    defer parsed.deinit();
    const out = try jev_tool.execute(child, parsed.value);
    defer std.testing.allocator.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "reasoning effort selected") != null);
    try std.testing.expect(child_pending.take(std.testing.io, p) != null);
    try std.testing.expect(root_pending.take(std.testing.io, p) == null);

    // Applied at the child's request boundary, to the child only.
    const Fake = struct {
        io: std.Io,
        gpa: Allocator,
        provider: Provider,
        jev_effort_pending: state.Pending = .{},
        reasoning: @import("main.zig").ReasoningEffort = .medium,
        sub: bool = true,
        fast: bool = false,
        ultracode_mode: bool = false,
        show_thinking: bool = false,
        ai_title: bool = false,
    };
    var sub: Fake = .{ .io = std.testing.io, .gpa = std.testing.allocator, .provider = p };
    const token = sub.jev_effort_pending.begin(std.testing.io, p).?;
    try std.testing.expect(sub.jev_effort_pending.commit(std.testing.io, token, .high));
    state.apply(&sub);
    try std.testing.expectEqual(@import("main.zig").ReasoningEffort.high, sub.reasoning);
}
