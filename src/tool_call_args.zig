//! #752: tool-call argument strings must be JSON objects in replayable history.
//!
//! OpenAI chat and the Responses wire store `arguments` as a string. A truncated
//! stream used to persist that fragment, execute with an empty object (so bash
//! reported a missing `command`), then 400 every later request:
//! `function.arguments: arguments must be a valid JSON object string`.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const empty_object = "{}";
pub const invalid_exec_message = "tool call arguments were truncated or not a JSON object; the call was not executed";
/// #1218: the response stopped (output limit, or a stream that ended before
/// its terminal event) while this call was still being written. The model
/// gets the cause and the fix, not a malformed-JSON guess it retries as-is.
pub const cut_exec_message = "tool call arguments were truncated: the response ended before this call was complete (output limit or cut-off stream), so it was not executed. Re-issue it, with fewer or smaller calls per response";
/// Both refusals start with this; broken-call loop detection keys on it.
pub const truncated_prefix = "tool call arguments were truncated";

pub const Parsed = struct {
    input: Value,
    /// False: do not execute; persist `{}` instead of the raw fragment.
    valid: bool,
};

/// Empty arguments still run as `{}` (a completed empty call). Anything that is
/// not a JSON object — truncated strings, arrays, scalars — is invalid.
pub fn parse(alloc: Allocator, s: []const u8) Parsed {
    const t = std.mem.trim(u8, s, &std.ascii.whitespace);
    if (t.len == 0) return .{ .input = .{ .object = .empty }, .valid = true };
    const value = std.json.parseFromSliceLeaky(Value, alloc, t, .{ .allocate = .alloc_always }) catch
        return .{ .input = .{ .object = .empty }, .valid = false };
    if (value != .object) return .{ .input = .{ .object = .empty }, .valid = false };
    return .{ .input = value, .valid = true };
}

/// Why a streamed call is not executed. `cut`: the response stopped while
/// the call was still streaming (#1218), as opposed to one that finished
/// streaming but is not a JSON object.
pub const Refusal = enum { none, malformed, cut };

/// Stop reasons that end a response mid-output. None at all means the stream
/// ended before its terminal event.
pub fn responseCut(stop_reason: ?[]const u8) bool {
    const s = stop_reason orelse return true;
    return std.mem.eql(u8, s, "max_tokens") or std.mem.eql(u8, s, "length") or
        std.mem.eql(u8, s, "model_context_window_exceeded");
}

/// A cut call is refused unless its arguments already close as an object.
fn refusalFor(parsed: Parsed, raw: []const u8, cut: bool) Refusal {
    const finished = parsed.valid and std.mem.trim(u8, raw, &std.ascii.whitespace).len > 0;
    if (cut and !finished) return .cut;
    return if (parsed.valid) .none else .malformed;
}

/// Anthropic streams `tool_use.input` as partial_json. A fragment that is not
/// a JSON object (a cut-off stream, #1218) used to become `{}` and run as an
/// empty call (`missing or non-string argument: path`). It is stored as `{}`
/// so history replays, with a marker the step removes before refusing it.
const invalid_mark = "graff_invalid_input";

pub fn putStreamedInput(alloc: Allocator, block: *std.json.ObjectMap, json: []const u8, cut: bool) !void {
    const parsed = parse(alloc, json);
    try block.put(alloc, "input", parsed.input);
    const why = refusalFor(parsed, json, cut);
    if (why != .none) try block.put(alloc, invalid_mark, .{ .string = @tagName(why) });
}

/// The refusal putStreamedInput (or markChatCut) recorded, with the marker
/// removed so it is never replayed to the provider.
pub fn takeInvalidMark(block: *std.json.ObjectMap) Refusal {
    const kv = block.fetchOrderedRemove(invalid_mark) orelse return .none;
    return if (kv.value == .string and std.mem.eql(u8, kv.value.string, "cut")) .cut else .malformed;
}

/// Chat wire: mark an assembled `tool_calls[]` entry the response cut off.
pub fn markChatCut(alloc: Allocator, call: *std.json.ObjectMap) !void {
    try call.put(alloc, invalid_mark, .{ .string = "cut" });
}

test "a cut-off Anthropic tool input is refused, not run as {} (#1218)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cut: std.json.ObjectMap = .empty;
    try putStreamedInput(arena, &cut, "{\"path\":\"src/ma", false);
    try std.testing.expectEqual(@as(usize, 0), cut.get("input").?.object.count());
    try std.testing.expectEqual(Refusal.malformed, takeInvalidMark(&cut));
    try std.testing.expect(cut.get(invalid_mark) == null); // never replayed
    var whole: std.json.ObjectMap = .empty;
    try putStreamedInput(arena, &whole, "{\"path\":\"src/main.zig\"}", false);
    try std.testing.expectEqual(Refusal.none, takeInvalidMark(&whole));
    try std.testing.expectEqualStrings("src/main.zig", whole.get("input").?.object.get("path").?.string);
    // A response that stopped mid-call: nothing streamed, or a fragment, is cut;
    // arguments that already closed as an object still run.
    var empty: std.json.ObjectMap = .empty;
    try putStreamedInput(arena, &empty, "", true);
    try std.testing.expectEqual(Refusal.cut, takeInvalidMark(&empty));
    var partial: std.json.ObjectMap = .empty;
    try putStreamedInput(arena, &partial, "{\"path\":\"src/ma", true);
    try std.testing.expectEqual(Refusal.cut, takeInvalidMark(&partial));
    var closed: std.json.ObjectMap = .empty;
    try putStreamedInput(arena, &closed, "{\"path\":\"src/main.zig\"}", true);
    try std.testing.expectEqual(Refusal.none, takeInvalidMark(&closed));
    try std.testing.expect(std.mem.startsWith(u8, cut_exec_message, truncated_prefix));
    try std.testing.expect(std.mem.startsWith(u8, invalid_exec_message, truncated_prefix));
    try std.testing.expect(responseCut(null) and responseCut("max_tokens") and responseCut("length"));
    try std.testing.expect(!responseCut("tool_use") and !responseCut("tool_calls") and !responseCut("end_turn"));
}

/// `gpa` must free (session arena is bump-only). Used only to validate.
pub fn isObjectString(gpa: Allocator, s: []const u8) bool {
    const t = std.mem.trim(u8, s, &std.ascii.whitespace);
    if (t.len == 0 or t[0] != '{') return false;
    const parsed = std.json.parseFromSlice(Value, gpa, t, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

/// Rewrite OpenAI `tool_calls[].function.arguments` and Responses
/// `function_call.arguments` that are not JSON object strings. Ids / pairing stay.
pub fn repairHistory(gpa: Allocator, map_alloc: Allocator, messages: []Value) void {
    for (messages) |*m| repairMessage(gpa, map_alloc, m);
}

pub fn repairMessage(gpa: Allocator, map_alloc: Allocator, m: *Value) void {
    if (m.* != .object) return;
    const mtype = if (m.object.get("type")) |t| (if (t == .string) t.string else "") else "";
    if (std.mem.eql(u8, mtype, "function_call")) {
        repairArgumentsField(gpa, map_alloc, &m.object);
        return;
    }
    const tcs = m.object.get("tool_calls") orelse return;
    if (tcs != .array) return;
    for (tcs.array.items) |*tc| {
        if (tc.* != .object) continue;
        var function = tc.object.get("function") orelse continue;
        if (function != .object) continue;
        repairArgumentsField(gpa, map_alloc, &function.object);
    }
}

fn repairArgumentsField(gpa: Allocator, map_alloc: Allocator, obj: *std.json.ObjectMap) void {
    const args = obj.get("arguments") orelse {
        obj.put(map_alloc, "arguments", .{ .string = empty_object }) catch return;
        return;
    };
    if (args == .string and isObjectString(gpa, args.string)) return;
    obj.put(map_alloc, "arguments", .{ .string = empty_object }) catch return;
}

test "parse: empty is a completed empty object; truncated and non-objects are not" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        const p = parse(arena, "");
        try std.testing.expect(p.valid);
        try std.testing.expect(p.input == .object);
    }
    {
        const p = parse(arena, "  {}  ");
        try std.testing.expect(p.valid);
        try std.testing.expect(p.input == .object);
    }
    {
        const p = parse(arena, "{\"command\":\"echo hi\"}");
        try std.testing.expect(p.valid);
        try std.testing.expectEqualStrings("echo hi", p.input.object.get("command").?.string);
    }
    // Issue #752: unterminated command string, 750-byte class fragment.
    const truncated = "{\"command\":\"echo hi";
    {
        const p = parse(arena, truncated);
        try std.testing.expect(!p.valid);
        try std.testing.expect(p.input == .object);
        try std.testing.expectEqual(@as(usize, 0), p.input.object.count());
    }
    {
        const p = parse(arena, "[1,2]");
        try std.testing.expect(!p.valid);
    }
    {
        const p = parse(arena, "\"not-an-object\"");
        try std.testing.expect(!p.valid);
    }
}

test "repairHistory: openai tool_calls and responses function_call keep ids" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(Value, arena,
        \\[
        \\  {"role":"assistant","content":null,"tool_calls":[
        \\    {"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo hi"}}
        \\  ]},
        \\  {"role":"tool","tool_call_id":"c1","content":"missing or non-string argument: command"},
        \\  {"type":"function_call","call_id":"r1","name":"bash","arguments":"{\"command\":\"partial"},
        \\  {"role":"assistant","tool_calls":[
        \\    {"id":"c2","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}
        \\  ]}
        \\]
    , .{});
    try std.testing.expect(parsed == .array);
    repairHistory(gpa, arena, parsed.array.items);

    const tc0 = parsed.array.items[0].object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("c1", tc0.get("id").?.string);
    try std.testing.expectEqualStrings(empty_object, tc0.get("function").?.object.get("arguments").?.string);
    try std.testing.expectEqualStrings("c1", parsed.array.items[1].object.get("tool_call_id").?.string);

    const fc = parsed.array.items[2].object;
    try std.testing.expectEqualStrings("r1", fc.get("call_id").?.string);
    try std.testing.expectEqualStrings(empty_object, fc.get("arguments").?.string);

    const good = parsed.array.items[3].object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", good.get("function").?.object.get("arguments").?.string);

    // Repaired strings are JSON objects, so a later request body would accept them.
    try std.testing.expect(isObjectString(gpa, empty_object));
    try std.testing.expect(isObjectString(gpa, good.get("function").?.object.get("arguments").?.string));
    try std.testing.expect(!isObjectString(gpa, "{\"command\":\"echo hi"));
}
