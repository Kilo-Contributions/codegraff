const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const testing = std.testing;
const importer = @import("adopt_sessions.zig");
const converter = @import("adopt_conversation.zig");

const transcript =
    \\{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"Fix the widget"}}
    \\{"type":"assistant","uuid":"a1","message":{"model":"claude-sonnet-4-5","content":[{"type":"thinking","thinking":"secret","signature":"signed"},{"type":"redacted_thinking","data":"opaque"}]}}
    \\{"type":"assistant","uuid":"a2","message":{"model":"claude-sonnet-4-5","content":[{"type":"text","text":"Checking"}]}}
    \\{"type":"assistant","uuid":"a3","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"pwd"}}]}}
    \\{"type":"assistant","uuid":"a3","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"pwd"}}]}}
    \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","is_error":true,"content":[{"type":"text","text":"not found"}]}]}}
    \\{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sidechain secret"}]}}
    \\{"type":"assistant","timestamp":"2026-01-01T00:01:00.123Z","message":{"content":[{"type":"text","text":"Done"}]}}
    \\{"type":"progress","data":{"irrelevant":"progress"}}
;

fn blocks(msg: Value) []const Value {
    return msg.object.get("content").?.array.items;
}

test "Claude conversion preserves text tool pairs model and time without signed thinking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try converter.convert(a, transcript, "/project");
    try testing.expectEqual(@as(usize, 4), c.messages.items.len);
    try testing.expectEqualStrings("Fix the widget", c.title);
    try testing.expectEqualStrings("claude-sonnet-4-5", c.model);
    try testing.expectEqual(@as(i64, 1767225660123), c.updated_ms);
    try testing.expectEqual(@as(usize, 2), blocks(c.messages.items[1]).len);
    const call = blocks(c.messages.items[1])[1].object;
    try testing.expectEqualStrings("tool-1", converter.string(call, "id").?);
    try testing.expectEqualStrings("pwd", converter.string(call.get("input").?.object, "command").?);
    const output = blocks(c.messages.items[2])[0].object;
    try testing.expectEqualStrings("tool-1", converter.string(output, "tool_use_id").?);
    try testing.expect(output.get("is_error").?.bool);
    const serialized = try std.json.Stringify.valueAlloc(a, Value{ .array = c.messages }, .{});
    try testing.expect(std.mem.indexOf(u8, serialized, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, serialized, "signature") == null);
    try testing.expect(std.mem.indexOf(u8, serialized, "not found") != null);
}

test "Claude interrupted calls get an error receipt and orphan results are discarded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try converter.convert(arena.allocator(),
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"orphan","content":"orphan"},{"type":"text","text":"Continue"}]}}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"unfinished","name":"Edit","input":{}}]}}
        \\{"type":"user","message":{"content":"next prompt"}}
    , "/project");
    try testing.expectEqual(@as(usize, 3), c.messages.items.len);
    const user = blocks(c.messages.items[2]);
    try testing.expectEqual(@as(usize, 2), user.len);
    try testing.expectEqualStrings("unfinished", converter.string(user[0].object, "tool_use_id").?);
    try testing.expect(user[0].object.get("is_error").?.bool);
    try testing.expectEqualStrings("next prompt", converter.string(user[1].object, "text").?);
}

test "Claude metadata titles have priority and incomplete final lines are tolerated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try converter.convert(a,
        \\{"type":"summary","summary":"Summary"}
        \\{"type":"custom-title","customTitle":"Named conversation"}
        \\{"type":"ai-title","aiTitle":"Generated title"}
        \\{"type":"user","message":{"content":"Question"}}
        \\{"type":"assistant"
    , "/project");
    try testing.expectEqualStrings("Named conversation", c.title);
    try testing.expectError(error.InvalidTranscript, converter.convert(a, "bad\n{}", "/project"));
    try testing.expectError(error.EmptyTranscript, converter.convert(a, "{\"type\":\"progress\"}", "/project"));
    try testing.expectError(error.OtherWorkspace, converter.convert(a, "{\"cwd\":\"/other\",\"type\":\"user\",\"message\":{\"content\":\"wrong\"}}", "/project"));
}

test "Claude UTC timestamp parser validates dates and leap years" {
    try testing.expectEqual(@as(i64, 0), converter.timestampMs("1970-01-01T00:00:00Z").?);
    try testing.expectEqual(@as(i64, 1709251199999), converter.timestampMs("2024-02-29T23:59:59.999Z").?);
    try testing.expect(converter.timestampMs("2023-02-29T00:00:00.000Z") == null);
    try testing.expect(converter.timestampMs("2026-01-01T24:00:00.000Z") == null);
    try testing.expect(converter.timestampMs("bad") == null);
}

test "Claude import command creates discoverable loadable saves and never overwrites" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    const cwd = try std.fmt.allocPrint(a, "{s}/project.with_punctuation", .{base});
    try Io.Dir.cwd().createDirPath(io, cwd);
    const source = try std.fmt.allocPrint(a, "{s}/.claude/projects/{s}", .{ home, try importer.projectSlug(a, cwd) });
    try Io.Dir.cwd().createDirPath(io, source);
    const input = try std.fmt.allocPrint(a, "{s}/fixture.jsonl", .{source});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = input, .data = transcript });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/sessions-index.json", .{source}), .data =
        \\{"entries":[{"sessionId":"fixture","customTitle":"Widget task","modified":"2026-01-01T00:02:00.000Z"}]}
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/broken.jsonl", .{source}), .data = "invalid\n{}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/agent-child.jsonl", .{source}), .data = transcript });
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/fixture/subagents", .{source}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/fixture/subagents/child.jsonl", .{source}), .data = transcript });

    // First-run adoption must not copy conversation history.
    _ = try @import("adopt.zig").maybeFirstRun(io, a, home, cwd);
    const saved = try std.fmt.allocPrint(a, "{s}/.graff/sessions/claude-fixture.session.json", .{cwd});
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, saved, .{}));
    var out: Io.Writer.Allocating = .init(a);
    try @import("adopt.zig").command(io, a, home, cwd, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "imported 1 Claude conversation(s)") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "could not import 1") != null);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, saved, a, .limited(8 << 20));
    const meta = @import("session_index.zig").sessionMetaFromBytes(a, bytes);
    try testing.expectEqualStrings("Widget task", meta.title.?);
    try testing.expectEqual(@as(i64, 1767225720000), meta.updated_ms);
    try testing.expectEqualStrings(cwd, meta.workspace.?);
    try testing.expect((try Io.Dir.cwd().statFile(io, try std.fmt.allocPrint(a, "{s}/.graff/.gitignore", .{cwd}), .{})).size > 0);

    // Both frontends use this same session loader. Home discovery lets the
    // test exercise it without mutating the process cwd.
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var keys: @import("provider.zig").Keys = .{ .values = @splat("test-key") };
    var root: @import("agent.zig").Agent = .{
        .gpa = testing.allocator,
        .arena = a,
        .io = io,
        .client = &client,
        .provider = try keys.providerById("anthropic", "fixture"),
        .messages = std.json.Array.init(a),
        .sub = false,
        .label = "root",
        .out = null,
        .home = cwd,
    };
    const listing = @import("session_index.zig").listSavedSessionsAll(&root, a);
    var found = false;
    for (listing.items) |entry| {
        if (std.mem.eql(u8, entry.base, "claude-fixture")) found = true;
    }
    try testing.expect(found);
    try @import("session.zig").loadSession(&root, &keys, a, "claude-fixture");
    try testing.expectEqualStrings("Widget task", root.session_title.?);
    try testing.expectEqual(@as(usize, 4), root.messages.items.len);
    const body = try root.buildBody(null, false, false, false);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "not found") != null);
    try testing.expect(std.mem.indexOf(u8, body, "sidechain secret") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"thinking\":\"secret\"") == null);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = saved, .data = "continued in graff" });
    const again = try importer.run(io, a, home, cwd);
    try testing.expectEqual(@as(usize, 0), again.imported);
    try testing.expectEqual(@as(usize, 1), again.skipped);
    try testing.expectEqualStrings("continued in graff", try Io.Dir.cwd().readFileAlloc(io, saved, a, .limited(100)));
}

test "Claude import missing project is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try testing.expectEqual(@as(usize, 0), (try importer.run(testing.io, a, home, "/project")).imported);
    try testing.expectEqual(@as(usize, 0), (try importer.run(testing.io, a, "", "/project")).imported);
    try testing.expectEqualStrings("-a-b-c-d", try importer.projectSlug(a, "/a.b/c_d"));
}

test "selected import uses the configured graff provider without Claude credentials" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", a);
    const config = try std.fmt.allocPrint(a, "{s}/source-config", .{cwd});
    const source = try std.fmt.allocPrint(a, "{s}/projects/{s}", .{ config, try importer.projectSlug(a, cwd) });
    try Io.Dir.cwd().createDirPath(io, source);
    for ([_][]const u8{ "selected", "other" }) |id| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ source, id }), .data = transcript });
    }
    try testing.expectEqualStrings("claude-selected", try importer.importOne(io, a, config, cwd, "selected", null));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".graff/sessions/claude-other.session.json", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".mcp.json", .{}));
    try testing.expectError(error.ClaudeImportFailed, importer.importOne(io, a, config, cwd, "missing", null));
    try testing.expectError(error.InvalidSessionName, importer.importOne(io, a, config, cwd, "../selected", null));
    try testing.expectEqualStrings("claude-selected", try importer.importOne(io, a, config, cwd, "selected", null));

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var keys: @import("provider.zig").Keys = .{ .values = @splat("") };
    for ([_]@import("provider.zig").Provider.Kind{ .anthropic, .openai, .responses }) |kind| {
        var root: @import("agent.zig").Agent = .{
            .gpa = testing.allocator,
            .arena = a,
            .io = io,
            .client = &client,
            .provider = .{ .id = "configured-route", .kind = kind, .auth = .bearer, .url = "", .api_key = "configured-key", .model = "configured-model", .context = 100_000 },
            .messages = std.json.Array.init(a),
            .sub = false,
            .label = "root",
            .out = null,
            .home = cwd,
        };
        try @import("session.zig").loadSession(&root, &keys, a, "claude-selected");
        try testing.expectEqualStrings("configured-route", root.provider.id);
        try testing.expectEqualStrings("configured-model", root.provider.model);
        const body = try root.buildBody(null, false, false, false);
        defer testing.allocator.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "Fix the widget") != null);
        try testing.expect(std.mem.indexOf(u8, body, "pwd") != null);
        try testing.expect(std.mem.indexOf(u8, body, "not found") != null);
        try testing.expect(std.mem.indexOf(u8, body, "sidechain secret") == null);
        try testing.expect(std.mem.indexOf(u8, body, "\"thinking\":\"secret\"") == null);
    }
}
