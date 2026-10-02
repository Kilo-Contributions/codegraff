//! JSON literals in rlm scripts (ADR 0236): `ids = ["ISS-1", "ISS-2"]`,
//! `each(["ISS-1", "ISS-2"], tool, "id")`, `write_file("r.json", {"ids": ids})`.
//! A bound name inside a literal stands for its value: a bound result that is
//! JSON goes in as JSON, any other text as a JSON string. Python spellings of
//! the constants (True, False, None) and single-quoted strings are accepted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Bound = @import("spec_ptc.zig").Bound;

/// One past the bracket that closes the literal opening at `src[start]`
/// (`[` or `{`), skipping strings; null when it never closes.
pub fn scan(src: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '"', '\'' => i = (stringEnd(src, i) orelse return null) - 1,
            '[', '{' => depth += 1,
            ']', '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// The literal as canonical JSON text, bound names replaced by their values.
pub fn render(arena: Allocator, literal: []const u8, binds: []const Bound) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < literal.len) {
        const c = literal[i];
        if (c == '"' or c == '\'') {
            const end = stringEnd(literal, i) orelse return error.Unterminated;
            if (c == '"') try out.appendSlice(arena, literal[i..end]) else try appendString(arena, &out, literal[i + 1 .. end - 1]);
            i = end;
            continue;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var j = i + 1;
            while (j < literal.len and (std.ascii.isAlphanumeric(literal[j]) or literal[j] == '_')) j += 1;
            const word = literal[i..j];
            if (constant(word)) |json| try out.appendSlice(arena, json) else if (lookup(binds, word)) |text| try appendValue(arena, &out, text) else return error.UnknownName;
            i = j;
            continue;
        }
        try out.append(arena, c);
        i += 1;
    }
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, out.items, .{});
    return stringify(arena, parsed);
}

/// `name = <literal>`: a JSON array or object (bound names allowed inside), a
/// string, a number, a constant, or another bound name. A string binds its text; anything else
/// binds canonical JSON. Null when the statement is not this shape.
pub fn assign(arena: Allocator, stmt: []const u8, binds: []const Bound) !?Bound {
    const t = std.mem.trim(u8, stmt, " \t");
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    const name = std.mem.trim(u8, t[0..eq], " \t");
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return null;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return null;
    const rhs = std.mem.trim(u8, t[eq + 1 ..], " \t");
    if (rhs.len == 0 or rhs[0] == '=') return null;
    const text = switch (rhs[0]) {
        '[', '{' => blk: {
            if ((scan(rhs, 0) orelse return null) != rhs.len) return null;
            break :blk render(arena, rhs, binds) catch return null;
        },
        '"', '\'' => blk: {
            if ((stringEnd(rhs, 0) orelse return null) != rhs.len) return null;
            const json = if (rhs[0] == '"') rhs else try quoted(arena, rhs[1 .. rhs.len - 1]);
            const v = std.json.parseFromSliceLeaky(Value, arena, json, .{}) catch return null;
            break :blk v.string;
        },
        else => blk: {
            if (constant(rhs)) |json| break :blk json;
            if (lookup(binds, rhs)) |bound| break :blk bound; // an alias of a bound name
            _ = std.fmt.parseFloat(f64, rhs) catch return null;
            break :blk rhs;
        },
    };
    return .{ .name = try arena.dupe(u8, name), .text = text };
}

fn stringEnd(src: []const u8, start: usize) ?usize {
    const q = src[start];
    var i = start + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\') {
            i += 1;
            continue;
        }
        if (src[i] == q) return i + 1;
    }
    return null;
}

fn constant(word: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "True")) return "true";
    if (std.mem.eql(u8, word, "false") or std.mem.eql(u8, word, "False")) return "false";
    if (std.mem.eql(u8, word, "null") or std.mem.eql(u8, word, "None")) return "null";
    return null;
}

fn lookup(binds: []const Bound, name: []const u8) ?[]const u8 {
    var i = binds.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, binds[i].name, name)) return binds[i].text;
    }
    return null;
}

fn appendValue(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.json.parseFromSliceLeaky(Value, arena, trimmed, .{})) |_| {
        try out.appendSlice(arena, trimmed);
    } else |_| try appendString(arena, out, text);
}

fn appendString(arena: Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    try out.appendSlice(arena, try quoted(arena, raw));
}

fn quoted(arena: Allocator, raw: []const u8) ![]const u8 {
    return stringify(arena, Value{ .string = raw });
}

fn stringify(arena: Allocator, v: Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(v);
    return aw.toOwnedSlice();
}

test "render: JSON literals with bound names, Python constants and single quotes" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const binds = [_]Bound{ .{ .name = "ids", .text = "[\"ISS-1\",\"ISS-2\"]" }, .{ .name = "note", .text = "plain text" } };
    try std.testing.expectEqualStrings("[\"ISS-1\",\"ISS-2\"]", try render(a, "[\"ISS-1\", \"ISS-2\"]", &.{}));
    try std.testing.expectEqualStrings("{\"ids\":[\"ISS-1\",\"ISS-2\"],\"note\":\"plain text\",\"ok\":true,\"x\":null}", try render(a, "{\"ids\": ids, \"note\": note, \"ok\": True, \"x\": None}", &binds));
    try std.testing.expectEqualStrings("[\"a\",[\"ISS-1\",\"ISS-2\"]]", try render(a, "['a', ids]", &binds));
    try std.testing.expectError(error.UnknownName, render(a, "[missing]", &binds));
    try std.testing.expectEqual(@as(?usize, 11), scan("[\"a]\", [1]] tail", 0));
    try std.testing.expect(scan("[1, 2", 0) == null);
}

test "assign: literals bind; calls and expressions do not" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const binds = [_]Bound{.{ .name = "c1", .text = "{\"n\":2}" }};
    try std.testing.expectEqualStrings("[\"ISS-1\",\"ISS-2\"]", (try assign(a, "ids = [\"ISS-1\", \"ISS-2\"]", &.{})).?.text);
    try std.testing.expectEqualStrings("[{\"n\":2}]", (try assign(a, "all = [c1]", &binds)).?.text);
    try std.testing.expectEqualStrings("[]", (try assign(a, "a = []", &.{})).?.text);
    try std.testing.expectEqualStrings("{\"issue_count\": 8", (try assign(a, "rows = \"{\\\"issue_count\\\": 8\"", &.{})).?.text);
    try std.testing.expectEqualStrings("hi", (try assign(a, "s = 'hi'", &.{})).?.text);
    try std.testing.expectEqualStrings("3", (try assign(a, "n = 3", &.{})).?.text);
    try std.testing.expectEqualStrings("{\"n\":2}", (try assign(a, "first = c1", &binds)).?.text);
    try std.testing.expect((try assign(a, "x = read_file(\"a\")", &.{})) == null);
    try std.testing.expect((try assign(a, "line = ids[0] + \"|\"", &.{})) == null);
    try std.testing.expect((try assign(a, "x == 3", &.{})) == null);
}
