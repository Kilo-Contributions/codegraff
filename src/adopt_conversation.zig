//! Claude JSONL → ordinary Anthropic-wire saved history (#1495).
const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Conversation = struct {
    messages: std.json.Array,
    title: []const u8 = "Imported Claude conversation",
    model: []const u8 = @import("provider.zig").provider_specs[0].default_model,
    updated_ms: i64 = 0,
    title_priority: u8 = 0,
};

/// Foreign tool receipts remain historical context across wire formats. They
/// never become executable calls on the newly selected provider.
pub fn forProvider(a: Allocator, history: std.json.Array, kind: @import("provider.zig").Provider.Kind) !std.json.Array {
    if (kind == .anthropic) return history;
    var out = std.json.Array.init(a);
    for (history.items) |msg| {
        const role = string(msg.object, "role") orelse continue;
        const content = msg.object.get("content") orelse continue;
        var body: std.Io.Writer.Allocating = .init(a);
        if (content == .string) {
            try body.writer.writeAll(content.string);
        } else if (content == .array) {
            for (content.array.items) |block| {
                if (block != .object) continue;
                const typ = string(block.object, "type") orelse continue;
                if (std.mem.eql(u8, typ, "text")) {
                    try body.writer.print("{s}\n", .{string(block.object, "text") orelse ""});
                } else if (std.mem.eql(u8, typ, "tool_use")) {
                    try body.writer.print("Historical tool call {s} ({s}): {s}\n", .{
                        string(block.object, "name") orelse "tool",
                        string(block.object, "id") orelse "",
                        try std.json.Stringify.valueAlloc(a, block.object.get("input") orelse .null, .{}),
                    });
                } else if (std.mem.eql(u8, typ, "tool_result")) {
                    try body.writer.print("Historical tool result ({s}){s}: {s}\n", .{
                        string(block.object, "tool_use_id") orelse "",
                        if (flag(block.object, "is_error")) " [error]" else "",
                        @import("messages.zig").toolContentString(a, block.object.get("content") orelse .null),
                    });
                }
            }
        }
        const trimmed = std.mem.trim(u8, body.written(), " \t\r\n");
        if (trimmed.len > 0) try out.append(try @import("messages.zig").textMessage(a, role, trimmed));
    }
    return out;
}

pub fn string(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn flag(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

pub fn text(a: Allocator, body: []const u8) !Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "type", .{ .string = "text" });
    try obj.put(a, "text", .{ .string = body });
    return .{ .object = obj };
}

fn append(a: Allocator, history: *std.json.Array, role: []const u8, block: Value) !void {
    if (history.items.len > 0) {
        const last = &history.items[history.items.len - 1];
        if (std.mem.eql(u8, string(last.object, "role").?, role)) {
            try last.object.getPtr("content").?.array.append(block);
            return;
        }
    }
    var blocks = std.json.Array.init(a);
    try blocks.append(block);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "role", .{ .string = role });
    try obj.put(a, "content", .{ .array = blocks });
    try history.append(.{ .object = obj });
}

pub fn convert(a: Allocator, data: []const u8, cwd: []const u8) !Conversation {
    var result: Conversation = .{ .messages = std.json.Array.init(a) };
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var calls: std.StringHashMapUnmanaged(void) = .empty;
    var outputs: std.StringHashMapUnmanaged(void) = .empty;
    var title_rank: u8 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const entry = std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }) catch {
            // A running/crashed writer can leave only its final line unfinished.
            if (lines.peek() == null) break;
            return error.InvalidTranscript;
        };
        if (entry != .object or flag(entry.object, "isSidechain")) continue;
        const obj = entry.object;
        if (string(obj, "cwd")) |workspace| {
            // Encoded project paths can collide (e.g. a-b and a/b).
            if (!@import("session_index.zig").sameWorkspace(workspace, cwd)) return error.OtherWorkspace;
        }
        const typ = string(obj, "type") orelse continue;
        if (string(obj, "timestamp")) |ts| result.updated_ms = @max(result.updated_ms, timestampMs(ts) orelse 0);
        const rank: u8 = if (std.mem.eql(u8, typ, "custom-title")) 3 else if (std.mem.eql(u8, typ, "ai-title")) 2 else if (std.mem.eql(u8, typ, "summary")) 1 else 0;
        if (rank > 0 and rank >= title_rank) {
            if (string(obj, if (rank == 3) "customTitle" else if (rank == 2) "aiTitle" else "summary")) |title| {
                result.title = title;
                title_rank = rank;
            }
        }
        if (!std.mem.eql(u8, typ, "user") and !std.mem.eql(u8, typ, "assistant")) continue;
        if (string(obj, "uuid")) |uuid| {
            const gop = try seen.getOrPut(a, uuid);
            if (gop.found_existing) continue;
        }
        const msg = obj.get("message") orelse continue;
        if (msg != .object) continue;
        if (std.mem.eql(u8, typ, "assistant")) {
            if (string(msg.object, "model")) |model| {
                if (std.mem.startsWith(u8, model, "claude-")) result.model = model;
            }
        }
        const content = msg.object.get("content") orelse continue;
        if (content == .string) {
            if (content.string.len > 0) try append(a, &result.messages, typ, try text(a, content.string));
            continue;
        }
        if (content != .array) continue;
        for (content.array.items) |block| {
            if (block != .object) continue;
            const bt = string(block.object, "type") orelse continue;
            if (std.mem.eql(u8, bt, "text")) {
                if (string(block.object, "text")) |body| try append(a, &result.messages, typ, try text(a, body));
            } else if (std.mem.eql(u8, typ, "assistant") and std.mem.eql(u8, bt, "tool_use")) {
                const id = string(block.object, "id") orelse continue;
                const name = string(block.object, "name") orelse continue;
                const input = block.object.get("input") orelse continue;
                if (input != .object) continue;
                const gop = try calls.getOrPut(a, id);
                if (gop.found_existing) continue;
                var tool: std.json.ObjectMap = .empty;
                try tool.put(a, "type", .{ .string = "tool_use" });
                try tool.put(a, "id", .{ .string = id });
                try tool.put(a, "name", .{ .string = name });
                try tool.put(a, "input", input);
                try append(a, &result.messages, typ, .{ .object = tool });
            } else if (std.mem.eql(u8, typ, "user") and std.mem.eql(u8, bt, "tool_result")) {
                const id = string(block.object, "tool_use_id") orelse continue;
                if (!calls.contains(id) or !pendingTool(result.messages.items, id)) continue;
                const gop = try outputs.getOrPut(a, id);
                if (gop.found_existing) continue;
                var tool: std.json.ObjectMap = .empty;
                try tool.put(a, "type", .{ .string = "tool_result" });
                try tool.put(a, "tool_use_id", .{ .string = id });
                var body: Value = block.object.get("content") orelse .{ .string = "" };
                if (body == .array) {
                    var blocks = std.json.Array.init(a);
                    for (body.array.items) |b| {
                        if (b == .object) {
                            if (string(b.object, "type")) |t| {
                                if (std.mem.eql(u8, t, "text")) {
                                    if (string(b.object, "text")) |s| try blocks.append(try text(a, s));
                                }
                            }
                        }
                    }
                    body = .{ .array = blocks };
                } else if (body != .string) body = .{ .string = try std.json.Stringify.valueAlloc(a, body, .{}) };
                try tool.put(a, "content", body);
                if (flag(block.object, "is_error")) try tool.put(a, "is_error", .{ .bool = true });
                try append(a, &result.messages, typ, .{ .object = tool });
            }
        }
    }
    if (result.messages.items.len == 0) return error.EmptyTranscript;
    // Resolve interrupted calls without replaying them. Keep each result directly
    // after its assistant turn; orphan results never enter the imported history.
    var history = std.json.Array.init(a);
    var i: usize = 0;
    while (i < result.messages.items.len) : (i += 1) {
        const msg = result.messages.items[i];
        try history.append(msg);
        if (!std.mem.eql(u8, string(msg.object, "role").?, "assistant")) continue;
        var user = std.json.Array.init(a);
        var rest = std.json.Array.init(a);
        if (i + 1 < result.messages.items.len) {
            const next = result.messages.items[i + 1];
            for (next.object.get("content").?.array.items) |b| {
                if (std.mem.eql(u8, string(b.object, "type").?, "tool_result")) try user.append(b) else try rest.append(b);
            }
        }
        for (msg.object.get("content").?.array.items) |b| {
            if (!std.mem.eql(u8, string(b.object, "type").?, "tool_use")) continue;
            const id = string(b.object, "id").?;
            var found = false;
            for (user.items) |u| {
                if (std.mem.eql(u8, string(u.object, "tool_use_id").?, id)) found = true;
            }
            if (found) continue;
            var missing: std.json.ObjectMap = .empty;
            try missing.put(a, "type", .{ .string = "tool_result" });
            try missing.put(a, "tool_use_id", .{ .string = id });
            try missing.put(a, "content", .{ .string = "Claude transcript ended before this tool result was recorded. Check whether it took effect before retrying." });
            try missing.put(a, "is_error", .{ .bool = true });
            try user.append(.{ .object = missing });
        }
        try user.appendSlice(rest.items);
        if (user.items.len > 0) {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "role", .{ .string = "user" });
            try obj.put(a, "content", .{ .array = user });
            try history.append(.{ .object = obj });
            if (i + 1 < result.messages.items.len) i += 1;
        }
    }
    result.messages = history;
    result.title_priority = title_rank;
    if (title_rank == 0) {
        for (history.items) |msg| {
            const prompt = @import("messages.zig").userPromptText(msg) orelse continue;
            const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
            if (trimmed.len == 0) continue;
            result.title = @import("util.zig").utf8Prefix(trimmed, @min(trimmed.len, 80));
            break;
        }
    }
    return result;
}

fn pendingTool(history: []const Value, id: []const u8) bool {
    var i = history.len;
    while (i > 0) {
        i -= 1;
        const msg = history[i];
        if (!std.mem.eql(u8, string(msg.object, "role").?, "assistant")) continue;
        for (msg.object.get("content").?.array.items) |block| {
            if (string(block.object, "id")) |call_id| {
                if (std.mem.eql(u8, call_id, id)) return true;
            }
        }
        return false;
    }
    return false;
}

/// Date.toISOString timestamps emitted by Claude's transcript writer (UTC).
pub fn timestampMs(ts: []const u8) ?i64 {
    if ((ts.len != 24 and ts.len != 20) or ts[4] != '-' or ts[7] != '-' or ts[10] != 'T' or ts[13] != ':' or ts[16] != ':' or ts[ts.len - 1] != 'Z') return null;
    const year = std.fmt.parseInt(u16, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, ts[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, ts[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, ts[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, ts[17..19], 10) catch return null;
    const ms: i64 = if (ts.len == 24 and ts[19] == '.') std.fmt.parseInt(u16, ts[20..23], 10) catch return null else if (ts.len == 20) 0 else return null;
    if (year < 1970 or month == 0 or month > 12 or day == 0 or hour > 23 or minute > 59 or second > 59) return null;
    const leap = std.time.epoch.isLeapYear(year);
    const months = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > months[month - 1]) return null;
    const y: i64 = year - 1;
    var days: i64 = (@as(i64, year) - 1970) * 365 + (@divTrunc(y, 4) - 492) - (@divTrunc(y, 100) - 19) + (@divTrunc(y, 400) - 4);
    for (months[0 .. month - 1]) |n| days += n;
    days += day - 1;
    return ((days * 24 + hour) * 3600 + @as(i64, minute) * 60 + second) * 1000 + ms;
}
