//! Slim rlm reducers: `len(x)` and `project(x, field)`.
//!
//! ADR 0029: `each()` without a way to print a small summary made grok-4.6
//! dump fat MCP binds or invent `for`/`len`. These two stay data helpers,
//! not a general language.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const spec_ptc = @import("spec_ptc.zig");
const rlm_spec = @import("rlm_spec.zig");
const rlm_mcp = @import("rlm_mcp.zig");
const mcp_shapes = @import("mcp_shapes.zig");

pub const StmtHit = rlm_mcp.StmtHit;

pub fn evalStmt(
    arena: Allocator,
    gpa: Allocator,
    stmt: []const u8,
    binds: []const rlm_spec.Binding,
    bind_out: *std.ArrayList(rlm_spec.Binding),
) !StmtHit {
    // #1536: a trailing `# comment` is stripped like it is for a host call.
    const trimmed = std.mem.trim(u8, spec_ptc.stripComment(stmt), " \t");
    var rest = trimmed;
    var assign: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
        const lhs = std.mem.trim(u8, trimmed[0..eq], " \t");
        const rhs = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (lhs.len > 0 and isReducer(rhs)) {
            assign = lhs;
            rest = rhs;
        }
    }
    const text = evalExpr(arena, rest, binds) catch |err| switch (err) {
        error.Miss => return .miss,
        else => return .{ .fail = try failText(gpa, rest, err) },
    };
    if (assign) |nm| try bind_out.append(arena, .{
        .name = try arena.dupe(u8, nm),
        .text = try arena.dupe(u8, text),
    });
    return .ok;
}

/// `len(...)` or `project(...)`, whatever is inside. Once a statement has
/// this shape it is a reducer: a failure says why, it never falls through
/// to "unsupported statement" (#1536).
fn isReducer(expr: []const u8) bool {
    const t = std.mem.trim(u8, expr, " \t");
    if (t.len == 0 or t[t.len - 1] != ')') return false;
    return std.mem.startsWith(u8, t, "len(") or std.mem.startsWith(u8, t, "project(");
}

pub const Error = error{ Miss, BadArgs, NotBound, NotArray, NoField } || Allocator.Error || std.Io.Writer.Error;

/// Resolve `len(x)` / `project(x, "field")` for `print(...)`. error.Miss
/// means the text is not a reducer; any other error is the reducer failing.
pub fn evalExpr(arena: Allocator, expr: []const u8, binds: []const rlm_spec.Binding) Error![]const u8 {
    const t = std.mem.trim(u8, spec_ptc.stripComment(expr), " \t");
    if (!isReducer(t)) return error.Miss;
    const is_len = std.mem.startsWith(u8, t, "len(");
    const inner = t[(if (is_len) "len(".len else "project(".len) .. t.len - 1];
    const parts = spec_ptc.splitTopLevel(arena, inner, ',') catch return error.BadArgs;
    if (parts.len != @as(usize, if (is_len) 1 else 2)) return error.BadArgs;
    const items = try jsonArray(arena, try argValue(binds, parts[0]));
    if (is_len) return try std.fmt.allocPrint(arena, "{d}", .{items.len});
    const field = stripQuotes(dropKeyword(parts[1]));
    if (field.len == 0) return error.BadArgs;
    var out: std.ArrayList(u8) = .empty;
    var found = items.len == 0;
    try out.append(arena, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(arena, ',');
        const v = try fieldValue(arena, item, field);
        if (v != null) found = true;
        try out.appendSlice(arena, v orelse "null");
    }
    // A field some rows lack reads null; one no row has is a typo.
    if (!found) return error.NoField;
    try out.append(arena, ']');
    return out.toOwnedSlice(arena);
}

/// The first argument: a bound name's text, or a JSON literal. `x=issues`
/// spells the same argument as a keyword, as host calls may.
fn argValue(binds: []const rlm_spec.Binding, arg: []const u8) Error![]const u8 {
    const t = dropKeyword(arg);
    if (bindText(binds, t)) |text| return text;
    if (t.len > 0 and (t[0] == '[' or t[0] == '{')) return t;
    return error.NotBound;
}

/// `field="id"` → `"id"`; a bare value is returned as is.
fn dropKeyword(arg: []const u8) []const u8 {
    const t = std.mem.trim(u8, arg, " \t");
    var i: usize = 0;
    while (i < t.len and (std.ascii.isAlphanumeric(t[i]) or t[i] == '_')) i += 1;
    if (i == 0 or i == t.len or std.ascii.isDigit(t[0])) return t;
    const rest = std.mem.trimStart(u8, t[i..], " \t");
    if (rest.len < 2 or rest[0] != '=' or rest[1] == '=') return t;
    return std.mem.trim(u8, rest[1..], " \t");
}

/// What went wrong, in terms of the documented call.
pub fn failText(gpa: Allocator, expr: []const u8, err: Error) ![]u8 {
    const why = switch (err) {
        error.BadArgs => "takes len(x) or project(x, \"field\"), x a bound name or a JSON literal",
        error.NotBound => "its first argument is not a bound name; bind the result first (x = tool(...))",
        error.NotArray => "its first argument is not a JSON array (or an object holding one); write_file it and use shell to parse other text",
        error.NoField => "no item has that field; print(x) lists the fields a row has",
        else => "failed",
    };
    return std.fmt.allocPrint(gpa, "rlm: {s}: {s}", .{ std.mem.trim(u8, expr, " \t"), why });
}

fn bindText(binds: []const rlm_spec.Binding, name: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, name, " \t");
    var i = binds.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, binds[i].name, t)) return binds[i].text;
    }
    return null;
}

fn stripQuotes(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

fn jsonArray(arena: Allocator, text: []const u8) Error![]const Value {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const parsed = std.json.parseFromSlice(Value, arena, trimmed, .{}) catch return error.NotArray;
    if (parsed.value == .array) return parsed.value.array.items;
    if (parsed.value == .object) {
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .array) return e.value_ptr.array.items;
        }
    }
    return error.NotArray;
}

/// The field's JSON text, or null when this item does not carry it.
fn fieldValue(arena: Allocator, item: Value, field: []const u8) Error!?[]const u8 {
    const v = switch (item) {
        // ADR 0238: an each() item is the tool's whole result; a comment
        // list answers through its printed fold, {n, latest_author}.
        .object => |obj| obj.get(field) orelse mcp_shapes.foldField(item, field) orelse return null,
        .array => mcp_shapes.foldField(item, field) orelse return null,
        else => return null,
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(v);
    return try aw.toOwnedSlice();
}

test "len() counts a JSON array bind" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const binds = [_]rlm_spec.Binding{.{ .name = "issues", .text = "[{\"id\":1},{\"id\":2},{\"id\":3}]" }};
    var bind_out: std.ArrayList(rlm_spec.Binding) = .empty;
    const hit = try evalStmt(arena, gpa, "n = len(issues)", &binds, &bind_out);
    try std.testing.expect(hit == .ok);
    try std.testing.expectEqualStrings("3", bind_out.items[0].text);
}

test "project() reads a field the printed view drops, and n/latest_author off an each() bind (ADR 0238)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const binds = [_]rlm_spec.Binding{
        .{ .name = "issues", .text = "[{\"id\":\"ISS-1\",\"priority\":2,\"estimate\":3},{\"id\":\"ISS-2\",\"priority\":1,\"estimate\":4}]" },
        .{ .name = "comments", .text = "[[{\"body\":\"a\",\"author\":{\"name\":\"ada\"},\"createdAt\":\"2026-08-11\"},{\"body\":\"b\",\"author\":{\"name\":\"bev\"},\"createdAt\":\"2026-08-12\"}],[]]" },
    };
    try std.testing.expectEqualStrings("[2,1]", try evalExpr(arena, "project(issues, \"priority\")", &binds));
    try std.testing.expectEqualStrings("[2,0]", try evalExpr(arena, "project(comments, \"n\")", &binds));
    try std.testing.expectEqualStrings("[\"bev\",null]", try evalExpr(arena, "project(comments, \"latest_author\")", &binds));
    try std.testing.expectError(error.NoField, evalExpr(arena, "project(comments, \"body\")", &binds));
}

test "project() extracts one field; print(len()) resolves" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const binds = [_]rlm_spec.Binding{.{ .name = "issues", .text = "[{\"id\":\"ISS-1\",\"title\":\"a\"},{\"id\":\"ISS-2\",\"title\":\"b\"}]" }};
    const ids = try evalExpr(arena, "project(issues, \"id\")", &binds);
    try std.testing.expectEqualStrings("[\"ISS-1\",\"ISS-2\"]", ids);
    const n = try evalExpr(arena, "len(issues)", &binds);
    try std.testing.expectEqualStrings("2", n);
}
