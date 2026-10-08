//! mcp_shapes tests moved off mcp_shapes.zig for the 600-line cap.

const std = @import("std");
const shapes = @import("mcp_shapes.zig");

test "annotate states the slim rule on every load result, stored shapes or not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    shapes.reset(gpa, io);
    defer shapes.reset(gpa, io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const annotated = try shapes.annotate(gpa, arena_state.allocator(), io, dir, "1 tool schema(s) below");
    try std.testing.expect(std.mem.startsWith(u8, annotated, "1 tool schema(s) below"));
    try std.testing.expect(std.mem.indexOf(u8, annotated, "latest_author") != null);
    try std.testing.expect(std.mem.indexOf(u8, annotated, "return_shapes") == null); // nothing stored yet
    try std.testing.expect(std.mem.indexOf(u8, @import("mcp_schema_gate.zig").tool_desc, "shown slimmed") == null); // never the prefix
}

test "slim drops description/body; comments fold to n and latest_author" {
    const gpa = std.testing.allocator;
    try std.testing.expect(shapes.slim(gpa, "[{\"id\":1}]") == null);
    const pad: [400]u8 = @splat('x');
    const pad_s: []const u8 = &pad;
    const issues = try std.fmt.allocPrint(gpa, "[{{\"id\":\"ISS-1\",\"identifier\":\"ENG-101\",\"title\":\"Login\",\"description\":\"{s}\",\"body\":\"KEEP-OUT\"}},{{\"id\":\"ISS-2\",\"identifier\":\"ENG-102\",\"title\":\"Tax\",\"description\":\"{s}\"}}]", .{ pad_s, pad_s });
    defer gpa.free(issues);
    const cut = shapes.slim(gpa, issues) orelse return error.ExpectedSlim;
    defer gpa.free(cut);
    try std.testing.expect(std.mem.indexOf(u8, cut, "ISS-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "ENG-101") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "Login") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "description") == null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "KEEP-OUT") == null);
    try std.testing.expect(std.mem.indexOf(u8, cut, pad_s) == null);

    const comments = try std.fmt.allocPrint(gpa, "[{{\"body\":\"old {s}\",\"author\":{{\"name\":\"ada\"}},\"createdAt\":\"2026-08-11T01:00:00Z\"}},{{\"body\":\"new {s}\",\"author\":{{\"name\":\"bev\"}},\"createdAt\":\"2026-08-12T02:00:00Z\"}}]", .{ pad_s, pad_s });
    defer gpa.free(comments);
    const folded = shapes.slim(gpa, comments) orelse return error.ExpectedCommentSlim;
    defer gpa.free(folded);
    try std.testing.expect(std.mem.indexOf(u8, folded, "\"n\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded, "bev") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded, "ada") == null);
    try std.testing.expect(std.mem.indexOf(u8, folded, "old ") == null);
    try std.testing.expect(std.mem.indexOf(u8, folded, pad_s) == null);
}

test "a direct call's slim result names a handle holding the full payload; with no handle target the cut stays plain JSON" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pad: [900]u8 = @splat('x');
    const fat = try std.fmt.allocPrint(gpa, "[{{\"id\":\"ISS-1\",\"title\":\"Login\",\"description\":\"{s}\",\"state\":\"open\"}}]", .{@as([]const u8, &pad)});
    const fat_len = fat.len;
    const kept = shapes.takeSlimKept(gpa, .{ .io = io, .dir = tmp.dir }, fat);
    defer gpa.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "ISS-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"state\"") == null); // dropped from the slim view...
    try std.testing.expect(std.mem.indexOf(u8, kept, "; fields: id, title, description, state;") != null); // ...but named (ADR 0240)
    const at = std.mem.indexOf(u8, kept, "handle tr_") orelse return error.MissingHandle;
    const id_end = std.mem.indexOfScalarPos(u8, kept, at + 7, ' ') orelse return error.MissingHandle;
    const rel = try std.fmt.allocPrint(gpa, ".graff/tool-results/{s}.txt", .{kept[at + 7 .. id_end]});
    defer gpa.free(rel);
    const whole = try tmp.dir.readFileAlloc(io, rel, gpa, .limited(1 << 20));
    defer gpa.free(whole);
    try std.testing.expectEqual(fat_len, whole.len); // ...but kept whole behind the handle
    try std.testing.expect(std.mem.indexOf(u8, whole, "\"state\":\"open\"") != null);

    const bind_src = try std.fmt.allocPrint(gpa, "[{{\"id\":\"ISS-2\",\"title\":\"T\",\"description\":\"{s}\"}}]", .{@as([]const u8, &pad)});
    const bind = shapes.takeSlimKept(gpa, null, bind_src);
    defer gpa.free(bind);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bind, .{}); // rlm parses binds as JSON
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, bind, "handle") == null);
}

test "infer strips values and keeps keys plus broad types" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const shape = try shapes.infer(a,
        \\[{"id":"ISS-1","title":"Login","n":3,"ok":true,"meta":{"x":1},"tags":["a"]}]
    );
    try std.testing.expect(std.mem.indexOf(u8, shape, "ISS-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, shape, "Login") == null);
    try std.testing.expect(std.mem.indexOf(u8, shape, "\"id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape, "string") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape, "number") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape, "bool") != null);
}

test "remember merges keys; annotate splices shapes; prefix text is untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..n];
    shapes.reset(gpa, io);
    defer shapes.reset(gpa, io);
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const ctx: @import("tools.zig").ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &dummy_client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .agent_cwd = dir,
    };
    shapes.remember(ctx, "mcp__linear__list_issues", "[{\"id\":\"A\",\"title\":\"t\"}]");
    shapes.remember(ctx, "mcp__linear__list_issues", "[{\"id\":\"B\",\"state\":\"open\"}]");
    const hit = shapes.lookup(io, "mcp__linear__list_issues") orelse return error.MissingShape;
    try std.testing.expect(std.mem.indexOf(u8, hit, "\"id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hit, "\"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hit, "\"state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hit, "\"A\"") == null);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const annotated = try shapes.annotate(gpa, arena_state.allocator(), io, dir, "1 tool schema(s) below\nmcp__linear__list_issues");
    try std.testing.expect(std.mem.indexOf(u8, annotated, "return_shapes") != null);
    try std.testing.expect(std.mem.indexOf(u8, annotated, "mcp__linear__list_issues") != null);
    try std.testing.expect(std.mem.indexOf(u8, annotated, "muscle:") == null);
    try std.testing.expect(std.mem.indexOf(u8, @import("mcp_schema_gate.zig").tool_desc, "return_shapes") == null);
    try std.testing.expect(std.mem.indexOf(u8, @import("rlm.zig").tool_desc, "muscle:") == null);
}

test "annotate writes a muscle playbook once two MCP shapes are stored" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..n];
    shapes.reset(gpa, io);
    defer shapes.reset(gpa, io);
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const ctx: @import("tools.zig").ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &dummy_client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .agent_cwd = dir,
    };
    shapes.remember(ctx, "mcp__linear__list_issues", "[{\"id\":\"A\"}]");
    shapes.remember(ctx, "mcp__linear__list_comments", "[{\"body\":\"b\",\"author\":\"ada\"}]");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const annotated = try shapes.annotate(gpa, arena_state.allocator(), io, dir, "2 tool schema(s)");
    try std.testing.expect(std.mem.indexOf(u8, annotated, "muscle:") != null);
    try std.testing.expect(std.mem.indexOf(u8, annotated, "each(") != null);
    try std.testing.expect(std.mem.indexOf(u8, @import("mcp_schema_gate.zig").tool_desc, "muscle:") == null);
}

test "print of an each() bind cuts every item; a bind that slim cannot cut prints whole (ADR 0238)" {
    const gpa = std.testing.allocator;
    const pad: [400]u8 = @splat('x');
    const pad_s: []const u8 = &pad;
    const each_bind = try std.fmt.allocPrint(gpa, "[[{{\"body\":\"{s}\",\"author\":{{\"name\":\"ada\"}},\"createdAt\":\"2026-08-11\"}},{{\"body\":\"{s}\",\"author\":{{\"name\":\"bev\"}},\"createdAt\":\"2026-08-12\"}}],[{{\"body\":\"{s}\",\"author\":{{\"name\":\"cam\"}},\"createdAt\":\"2026-08-13\"}}]]", .{ pad_s, pad_s, pad_s });
    defer gpa.free(each_bind);
    const shown = shapes.slim(gpa, each_bind) orelse return error.ExpectedEachSlim;
    defer gpa.free(shown);
    try std.testing.expectEqualStrings("[{\"n\":2,\"latest_author\":\"bev\"},{\"n\":1,\"latest_author\":\"cam\"}]", shown);
    const plain = try std.fmt.allocPrint(gpa, "[[1,2,3],[\"{s}\",\"{s}\"]]", .{ pad_s, pad_s });
    defer gpa.free(plain);
    try std.testing.expect(shapes.slim(gpa, plain) == null);
}

test "the slim rule says an rlm bind keeps every field (ADR 0238)" {
    try std.testing.expect(std.mem.indexOf(u8, shapes.slim_rule, "keeps every field") != null);
    try std.testing.expect(std.mem.indexOf(u8, shapes.slim_rule, "binds stay slimmed") == null);
    try std.testing.expect(std.mem.indexOf(u8, shapes.slim_rule, "write_file") != null);
}

test "fieldList names a list result's fields, and an each() bind's inner rows (ADR 0240)" {
    const gpa = std.testing.allocator;
    const rows = shapes.fieldList(gpa, "[{\"id\":\"ISS-1\",\"priority\":2,\"estimate\":3}]") orelse return error.NoFields;
    defer gpa.free(rows);
    try std.testing.expectEqualStrings("id, priority, estimate", rows);
    const nested = shapes.fieldList(gpa, "[[{\"body\":\"b\",\"author\":{\"name\":\"ada\"}}],[]]") orelse return error.NoFields;
    defer gpa.free(nested);
    try std.testing.expectEqualStrings("body, author", nested);
    try std.testing.expect(shapes.fieldList(gpa, "[1,2,3]") == null);
}

test "the slim rule says to compute inside the same script (ADR 0240)" {
    try std.testing.expect(std.mem.indexOf(u8, shapes.slim_rule, "run the computation inside the script") != null);
    try std.testing.expect(std.mem.indexOf(u8, shapes.slim_rule, "write_file(\"issues.json\", issues)") != null);
}

test "a comment fold names the issue every row shares, and only then" {
    const gpa = std.testing.allocator;
    const pad: [400]u8 = @splat('x');
    const pad_s: []const u8 = &pad;
    const shared = try std.fmt.allocPrint(gpa, "[{{\"issueId\":\"ISS-4\",\"body\":\"{s}\",\"author\":{{\"name\":\"gus\"}},\"createdAt\":\"2026-08-11\"}},{{\"issueId\":\"ISS-4\",\"body\":\"{s}\",\"author\":{{\"name\":\"jay\"}},\"createdAt\":\"2026-08-12\"}}]", .{ pad_s, pad_s });
    defer gpa.free(shared);
    const folded = shapes.slim(gpa, shared) orelse return error.ExpectedCommentSlim;
    defer gpa.free(folded);
    try std.testing.expectEqualStrings("{\"issue\":\"ISS-4\",\"n\":2,\"latest_author\":\"jay\"}", folded);

    const nested = try std.fmt.allocPrint(gpa, "[{{\"issue\":{{\"id\":\"u1\",\"identifier\":\"ENG-7\"}},\"body\":\"{s}\",\"author\":\"ada\"}},{{\"issue\":{{\"id\":\"u1\",\"identifier\":\"ENG-7\"}},\"body\":\"{s}\",\"author\":\"bev\"}}]", .{ pad_s, pad_s });
    defer gpa.free(nested);
    const nested_fold = shapes.slim(gpa, nested) orelse return error.ExpectedCommentSlim;
    defer gpa.free(nested_fold);
    try std.testing.expect(std.mem.startsWith(u8, nested_fold, "{\"issue\":\"ENG-7\","));

    // Rows that disagree, or a row without the key, name no issue.
    const mixed = try std.fmt.allocPrint(gpa, "[{{\"issueId\":\"ISS-1\",\"body\":\"{s}\",\"author\":\"ada\"}},{{\"issueId\":\"ISS-2\",\"body\":\"{s}\",\"author\":\"bev\"}},{{\"body\":\"{s}\",\"author\":\"cam\"}}]", .{ pad_s, pad_s, pad_s });
    defer gpa.free(mixed);
    const mixed_fold = shapes.slim(gpa, mixed) orelse return error.ExpectedCommentSlim;
    defer gpa.free(mixed_fold);
    try std.testing.expect(std.mem.indexOf(u8, mixed_fold, "issue") == null);
    try std.testing.expect(std.mem.indexOf(u8, shapes.slim_rule, "\"issue\"") != null);
}

test "a transcript's messages are never cut to their ids (#1426)" {
    const gpa = std.testing.allocator;
    const pad: [900]u8 = @splat('x');
    const pad_s: []const u8 = &pad;
    // One long message, and a window of several: both stay readable.
    const one = try std.fmt.allocPrint(gpa, "{{\"chatId\":\"c1\",\"total\":1,\"messages\":[{{\"id\":\"m1\",\"role\":\"assistant\",\"text\":\"{s}\"}}]}}", .{pad_s});
    defer gpa.free(one);
    try std.testing.expect(shapes.slim(gpa, one) == null);
    const many = try std.fmt.allocPrint(gpa, "{{\"messages\":[{{\"id\":\"m1\",\"role\":\"user\",\"text\":\"{s}\"}},{{\"id\":\"m2\",\"role\":\"assistant\",\"text\":\"done\"}}]}}", .{pad_s});
    defer gpa.free(many);
    try std.testing.expect(shapes.slim(gpa, many) == null);
    // Rows known only by an opaque id are content too.
    const bare = try std.fmt.allocPrint(gpa, "[{{\"id\":\"r1\",\"text\":\"{s}\"}}]", .{pad_s});
    defer gpa.free(bare);
    try std.testing.expect(shapes.slim(gpa, bare) == null);
}
