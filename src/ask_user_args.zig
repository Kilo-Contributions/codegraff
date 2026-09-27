//! ask_user argument shapes (#1308).
//!
//! The schema asks for `{question, options}`, but models also send the
//! arguments double-encoded as a JSON string, name the question `prompt` or
//! `message`, or use a `questions: [{question, options: [{label}]}]` list.
//! Reading only `question` showed a "(no question)" heading over options that
//! did render. `normalize` folds those shapes into `{question, options}` with
//! string options; a call with no question text at all goes back to the model
//! as an error instead of reaching the user.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const json_args = @import("json_args.zig");

pub const missing_text = "ask_user needs a non-empty `question` string. Call it again with the question text in `question` and any choices in `options`.";

const question_keys = [_][]const u8{ "question", "prompt", "message", "text", "query", "title", "header" };

pub const Args = struct {
    /// Null when no field carries non-empty question text.
    question: ?[]const u8,
    /// The arguments with `question` and string `options` filled in.
    input: Value,
};

pub fn normalize(a: Allocator, raw: Value) !Args {
    var input = raw;
    if (raw == .string) {
        const parsed: ?Value = std.json.parseFromSliceLeaky(Value, a, raw.string, .{ .allocate = .alloc_always }) catch null;
        if (parsed != null and parsed.? == .object) {
            input = parsed.?;
        } else {
            const q = nonEmpty(raw.string) orelse return .{ .question = null, .input = raw };
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "question", .{ .string = q });
            return .{ .question = q, .input = .{ .object = obj } };
        }
    }
    const src = json_args.object(input) orelse return .{ .question = null, .input = raw };
    var question = questionIn(src);
    var options = json_args.arrayOf(src, "options");
    if (json_args.arrayOf(src, "questions")) |items| if (items.len > 0) if (json_args.object(items[0])) |first| {
        if (question == null) question = questionIn(first);
        if (options == null) options = json_args.arrayOf(first, "options");
    };
    var obj = try src.clone(a);
    if (question) |q| try obj.put(a, "question", .{ .string = q });
    if (options) |opts| {
        var labels = std.json.Array.init(a);
        try labels.ensureTotalCapacity(opts.len);
        for (opts) |opt| labels.appendAssumeCapacity(if (optionLabel(opt)) |l| .{ .string = l } else opt);
        try obj.put(a, "options", .{ .array = labels });
    }
    return .{ .question = question, .input = .{ .object = obj } };
}

fn questionIn(o: std.json.ObjectMap) ?[]const u8 {
    for (question_keys) |k| if (json_args.str(o, k)) |s| if (nonEmpty(s)) |q| return q;
    return null;
}

fn optionLabel(opt: Value) ?[]const u8 {
    if (opt == .string) return opt.string;
    const o = json_args.object(opt) orelse return null;
    return json_args.str(o, "label") orelse json_args.str(o, "text") orelse json_args.str(o, "value");
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return if (t.len == 0) null else t;
}

const testing = std.testing;

fn run(a: Allocator, json: []const u8) !Args {
    return normalize(a, try std.json.parseFromSliceLeaky(Value, a, json, .{}));
}

test "the schema shape passes through unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try run(arena.allocator(), "{\"question\":\"Which target?\",\"options\":[\"npm\",\"GitHub\"]}");
    try testing.expectEqualStrings("Which target?", got.question.?);
    const opts = got.input.object.get("options").?.array.items;
    try testing.expectEqualStrings("GitHub", opts[1].string);
}

test "question aliases and a double-encoded argument string are read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Ship it?", (try run(a, "{\"prompt\":\"Ship it?\",\"options\":[\"yes\",\"no\"]}")).question.?);
    const enc = try run(a, "\"{\\\"question\\\":\\\"Which one?\\\",\\\"options\\\":[\\\"a\\\",\\\"b\\\"]}\"");
    try testing.expectEqualStrings("Which one?", enc.question.?);
    try testing.expectEqual(@as(usize, 2), enc.input.object.get("options").?.array.items.len);
    const plain = try run(a, "\"Proceed with the migration?\"");
    try testing.expectEqualStrings("Proceed with the migration?", plain.question.?);
    try testing.expectEqualStrings("Proceed with the migration?", plain.input.object.get("question").?.string);
}

test "a questions list supplies the question and labelled options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try run(arena.allocator(),
        \\{"questions":[{"question":"Which database?","header":"DB","options":[{"label":"Postgres","description":"x"},{"label":"SQLite"}]}]}
    );
    try testing.expectEqualStrings("Which database?", got.question.?);
    try testing.expectEqualStrings("Which database?", got.input.object.get("question").?.string);
    const opts = got.input.object.get("options").?.array.items;
    try testing.expectEqual(@as(usize, 2), opts.len);
    try testing.expectEqualStrings("Postgres", opts[0].string);
    try testing.expectEqualStrings("SQLite", opts[1].string);
}

test "options without any question text leave the question null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try run(a, "{\"options\":[\"a\",\"b\"]}")).question == null);
    try testing.expect((try run(a, "{\"question\":\"   \",\"options\":[\"a\"]}")).question == null);
    try testing.expect((try run(a, "{\"question\":42}")).question == null);
    try testing.expect((try run(a, "[1,2]")).question == null);
    try testing.expect((try run(a, "\"\"")).question == null);
}
