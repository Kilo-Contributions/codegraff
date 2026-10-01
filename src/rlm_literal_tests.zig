//! ADR 0236 end to end: JSON literals bind and pass as arguments, each()
//! takes plain items and a literal array, and refusals say what would work.

const std = @import("std");
const rlm = @import("rlm.zig");
const spec = @import("rlm_spec.zig");
const tools = @import("tools.zig");
const Fixture = @import("rlm_order_tests.zig").Fixture;
const gpa = std.testing.allocator;

const EchoHost = struct {
    fn run(ctx: tools.ToolCtx, call: @import("spec_ptc.zig").Call) tools.ToolOutput {
        return .{ .text = ctx.gpa.dupe(u8, call.args_json) catch unreachable };
    }
};

fn eachOut(f: *Fixture, arena: std.mem.Allocator, stmt: []const u8, binds: []const spec.Binding) !?[]const u8 {
    var outputs: std.ArrayList(spec.Binding) = .empty;
    const hit = try @import("rlm_mcp.zig").evalEach(f.ctx(), arena, stmt, binds, &outputs, EchoHost.run);
    switch (hit) {
        .ok => return if (outputs.items.len == 1) outputs.items[0].text else null,
        .fail => |e| {
            defer gpa.free(e.text);
            return error.EachFailed;
        },
        .miss => return null,
    }
}

test "ADR 0236: each() maps a literal array and plain ids, with or without a field" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const literal = (try eachOut(&f, a, "out = each([\"ISS-1\", \"ISS-2\"], \"read_file\", \"id\")", &.{})).?;
    try std.testing.expect(std.mem.indexOf(u8, literal, "ISS-1") != null and std.mem.indexOf(u8, literal, "ISS-2") != null);
    const ids = [_]spec.Binding{.{ .name = "ids", .text = "[\"ISS-1\",\"ISS-2\"]" }};
    const two_arg = (try eachOut(&f, a, "out = each(ids, \"read_file\")", &ids)).?;
    try std.testing.expect(std.mem.indexOf(u8, two_arg, "ISS-2") != null);
    const objects = [_]spec.Binding{.{ .name = "issues", .text = "[{\"id\":\"ISS-1\",\"title\":\"t\"}]" }};
    try std.testing.expect(std.mem.indexOf(u8, (try eachOut(&f, a, "out = each(issues, \"read_file\", \"id\")", &objects)).?, "ISS-1") != null);
}

test "ADR 0236: a missing field names the fields the items do have" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const binds = [_]spec.Binding{.{ .name = "issues", .text = "[{\"key\":\"ISS-1\",\"title\":\"t\"}]" }};
    var outputs: std.ArrayList(spec.Binding) = .empty;
    const hit = try @import("rlm_mcp.zig").evalEach(f.ctx(), arena.allocator(), "out = each(issues, \"read_file\", \"id\")", &binds, &outputs, EchoHost.run);
    try std.testing.expect(hit == .fail);
    defer gpa.free(hit.fail.text);
    try std.testing.expect(std.mem.indexOf(u8, hit.fail.text, "its fields: key, title") != null);
}

test "ADR 0236: a script binds literals and writes one built from bound names" {
    var f = try Fixture.init();
    defer f.deinit();
    const out = try f.run("ids = [\"a\", \"b\"]\nw = write_file(\"ids.json\", {\"ids\": ids, \"ok\": True})\nr = read_file(\"ids.json\")\nprint(r)");
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "{\"ids\":[\"a\",\"b\"],\"ok\":true}") != null);
}

test "ADR 0236: an unsupported statement lists the forms that work" {
    var f = try Fixture.init();
    defer f.deinit();
    const out = try f.run("ids = [\"a\"]\nline = ids[0] + \"|\"");
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "A statement is one of") != null);
}
