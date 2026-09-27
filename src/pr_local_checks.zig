//! Session-observed failing checks cannot be replaced by publication prose.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ToolCall = @import("tools.zig").ToolCall;
const ExecResult = @import("tools.zig").ExecResult;
const shell = @import("shell_tool.zig");

pub const Observer = struct {
    context: *anyopaque,
    state: *State,
    record: *const fn (*anyopaque, ToolCall, ExecResult) anyerror!void,
};

pub fn observeOutput(context: *anyopaque, call: ToolCall, result: ExecResult) !void {
    const root: *@import("agent.zig").Agent = @ptrCast(@alignCast(context));
    try record(root, call, result);
}

fn checkTail(command: []const u8) []const u8 {
    var rest = std.mem.trim(u8, command, " \t\r\n");
    while (std.mem.startsWith(u8, rest, "cd ")) {
        const sep = std.mem.indexOf(u8, rest, "&&") orelse break;
        rest = std.mem.trimStart(u8, rest[sep + 2 ..], " \t");
    }
    return rest;
}

pub fn isCheck(command: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, checkTail(command), " \t\r\n");
    var name = words.next() orelse return false;
    if (std.mem.eql(u8, name, "env")) name = words.next() orelse return false;
    while (std.mem.indexOfScalar(u8, name, '=')) |_| name = words.next() orelse return false;
    const executable = std.fs.path.basename(name);
    if (std.mem.eql(u8, executable, "pytest") or std.mem.startsWith(u8, executable, "eval-tier")) return true;
    const first = words.next() orelse return false;
    if (std.mem.eql(u8, executable, "node") or std.mem.eql(u8, executable, "bun")) {
        const script = std.fs.path.basename(first);
        if (std.mem.startsWith(u8, script, "test-") or std.mem.startsWith(u8, script, "test_") or std.mem.eql(u8, first, "--test")) return true;
    }
    if (std.mem.eql(u8, executable, "python") or std.mem.eql(u8, executable, "python3")) {
        if (std.mem.eql(u8, first, "-m")) {
            const module = words.next() orelse return false;
            return std.mem.eql(u8, module, "unittest") or std.mem.eql(u8, module, "pytest");
        }
        const script = std.fs.path.basename(first);
        return std.mem.startsWith(u8, script, "test-") or std.mem.startsWith(u8, script, "test_") or std.mem.startsWith(u8, script, "eval-tier");
    }
    if (std.mem.eql(u8, executable, "zig"))
        return std.mem.eql(u8, first, "test") or std.mem.eql(u8, first, "build");
    for ([_][]const u8{ "cargo", "go", "bun", "npm", "pnpm", "yarn", "make" }) |runner| {
        if (!std.mem.eql(u8, executable, runner)) continue;
        const task = if (std.mem.eql(u8, first, "run")) words.next() orelse return false else first;
        return std.mem.startsWith(u8, task, "test") or std.mem.eql(u8, task, "build") or std.mem.eql(u8, task, "check") or std.mem.eql(u8, task, "typecheck") or std.mem.eql(u8, task, "lint");
    }
    return false;
}

pub fn repositoryRoot(root: anytype, cwd: []const u8) ![]const u8 {
    const ev = @import("pr_evidence.zig");
    const found = ev.capture(root.gpa, root.io, root.arena, .{ .cwd = cwd, .selector = "" }, &.{ "git", "rev-parse", "--show-toplevel" }) catch return cwd;
    if (!std.fs.path.isAbsolute(found)) return cwd;
    var dir = std.Io.Dir.cwd().openDir(root.io, found, .{}) catch return cwd;
    defer dir.close(root.io);
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = dir.realPath(root.io, &path) catch return cwd;
    return root.arena.dupe(u8, path[0..len]);
}

pub fn record(root: anytype, call: ToolCall, result: ExecResult) !void {
    if (root.sub or !shell.isFamily(call.name)) return;
    // #1326: reading a backgrounded check's exit resolves it.
    if (shell.actionOf(call) == .output) return noteJobExits(root, result.text);
    const command = shell.runCommand(call) orelse return;
    root.publication_checks.observation_mutex.lockUncancelable(root.io);
    defer root.publication_checks.observation_mutex.unlock(root.io);
    const parsed = @import("pr_command.zig").literal(root.arena, command) catch return;
    if (!isCheck(try std.mem.join(root.arena, " ", parsed.argv))) return;
    const base = root.agent_cwd orelse ".";
    const path = if (parsed.cwd) |cwd| if (std.fs.path.isAbsolute(cwd)) cwd else try std.fs.path.join(root.arena, &.{ base, cwd }) else base;
    var dir = std.Io.Dir.cwd().openDir(root.io, path, .{}) catch try std.Io.Dir.cwd().openDir(root.io, base, .{});
    defer dir.close(root.io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = buffer[0..try dir.realPath(root.io, &buffer)];
    const repository = try repositoryRoot(root, cwd);
    try root.publication_checks.observeKnown(root.arena, cwd, repository, command, result);
    const ev = @import("pr_evidence.zig");
    const target = ev.Target{ .cwd = cwd, .selector = "" };
    const head = ev.localHead(root.gpa, root.io, root.arena, target) catch "";
    const dirty = ev.capture(root.gpa, root.io, root.arena, target, &.{ "git", "status", "--porcelain", "--untracked-files=no" }) catch "unknown";
    try root.publication_checks.recordReceipt(root.arena, .{ .repository = repository, .command = command, .head_after = head, .tracked_tree_clean_after = dirty.len == 0, .output = result.text, .failed = result.is_error or result.cancelled, .completed = !result.pending and std.mem.indexOf(u8, result.text, "[job ") == null });
}

/// The job id in `[job N started…`, `[job N: …` or `[job N exited…`.
fn jobIdIn(text: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, text, "[job ") orelse return null;
    const rest = text[at + "[job ".len ..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

/// Every job exit in `text`: an output read's `[job N: exited with code C]`
/// or a wake's `[job N exited C: cmd]` (#1326).
pub fn noteJobExits(root: anytype, text: []const u8) !void {
    if (root.sub) return;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "[job ")) |at| {
        pos = at + "[job ".len;
        const id = jobIdIn(text[at..]) orelse continue;
        var rest = text[pos..];
        while (rest.len > 0 and std.ascii.isDigit(rest[0])) rest = rest[1..];
        inline for (.{ ": exited with code ", " exited " }) |marker| if (std.mem.startsWith(u8, rest, marker)) {
            const digits = rest[marker.len..];
            var n: usize = 0;
            while (n < digits.len and std.ascii.isDigit(digits[n])) n += 1;
            if (std.fmt.parseInt(u8, digits[0..n], 10)) |code| try jobFinished(root, id, code, text) else |_| {}
        };
    }
}

/// Before a publication gate: resolve any tracked check whose background job
/// has since exited 0, whether or not the model read that exit.
pub fn resolveFinishedJobs(root: anytype) !void {
    if (root.sub) return;
    var ids: [16]u64 = undefined;
    var n: usize = 0;
    {
        root.publication_checks.observation_mutex.lockUncancelable(root.io);
        defer root.publication_checks.observation_mutex.unlock(root.io);
        for (root.publication_checks.failed.items) |entry| if (entry.job) |id| if (n < ids.len) {
            ids[n] = id;
            n += 1;
        };
    }
    for (ids[0..n]) |id| if (@import("job_notify.zig").exitCode(root.io, id)) |code| try jobFinished(root, id, code, "");
}

/// A tracked check that was running as job `id` has exited. Exit 0 resolves
/// it and leaves a completed receipt at the head it finished on; any other
/// code keeps it unresolved.
fn jobFinished(root: anytype, id: u64, exit_code: u8, output: []const u8) !void {
    const state = &root.publication_checks;
    state.observation_mutex.lockUncancelable(root.io);
    defer state.observation_mutex.unlock(root.io);
    for (state.failed.items, 0..) |entry, i| {
        if (entry.job != id) continue;
        if (exit_code != 0) return;
        _ = state.failed.orderedRemove(i);
        const ev = @import("pr_evidence.zig");
        const target = ev.Target{ .cwd = entry.cwd, .selector = "" };
        const head = ev.localHead(root.gpa, root.io, root.arena, target) catch "";
        const dirty = ev.capture(root.gpa, root.io, root.arena, target, &.{ "git", "status", "--porcelain", "--untracked-files=no" }) catch "unknown";
        try state.recordReceipt(root.arena, .{ .repository = entry.repository orelse entry.cwd, .command = entry.command, .head_after = head, .tracked_tree_clean_after = dirty.len == 0, .output = output, .failed = false, .completed = true });
        return;
    }
}

pub fn batchGate(root: anytype, calls: []const ToolCall, call: ToolCall) !?ExecResult {
    if (calls.len <= 1 or !shell.isFamily(call.name)) return null;
    const raw = shell.runCommand(call) orelse return null;
    const command = @import("pr_command.zig").parse(root.arena, raw) catch return null;
    if (!std.mem.eql(u8, command.verb, "create") and !std.mem.eql(u8, command.verb, "ready")) return null;
    if (std.mem.eql(u8, command.verb, "create") and command.draft()) return null;
    const text = "PR publication preflight: run non-draft publication in a separate tool call after other work finishes; write NOT performed.";
    root.emitToolRejected(call, "publication_batch", text);
    return .{ .text = text, .is_error = true };
}

pub const State = struct {
    /// `job`: the background job still running this check (#1326).
    const Entry = struct { cwd: []const u8, command: []const u8, repository: ?[]const u8 = null, job: ?u64 = null };
    pub const Receipt = struct { repository: []const u8, command: []const u8, head_after: []const u8, tracked_tree_clean_after: bool, output: []const u8, failed: bool, completed: bool, command_truncated: bool = false, output_truncated: bool = false };
    observation_mutex: std.Io.Mutex = .init,
    failed: std.ArrayList(Entry) = .empty,
    recent: std.ArrayList(Receipt) = .empty,

    pub fn snapshot(self: *State, arena: Allocator, io: std.Io) !State {
        self.observation_mutex.lockUncancelable(io);
        defer self.observation_mutex.unlock(io);
        var copy: State = .{};
        try copy.failed.appendSlice(arena, self.failed.items);
        try copy.recent.appendSlice(arena, self.recent.items);
        return copy;
    }

    pub fn recordReceipt(self: *State, arena: Allocator, receipt: Receipt) !void {
        var owned = receipt;
        owned.repository = try arena.dupe(u8, receipt.repository);
        var command_end = @min(receipt.command.len, 1024);
        while (command_end > 0 and !std.unicode.utf8ValidateSlice(receipt.command[0..command_end])) command_end -= 1;
        owned.command_truncated = receipt.command_truncated or command_end < receipt.command.len;
        owned.command = try arena.dupe(u8, receipt.command[0..command_end]);
        owned.head_after = try arena.dupe(u8, receipt.head_after);
        owned.output_truncated = receipt.output_truncated or receipt.output.len > 4096;
        var end = @min(receipt.output.len, 4096);
        while (end > 0 and !std.unicode.utf8ValidateSlice(receipt.output[0..end])) end -= 1;
        owned.output_truncated = owned.output_truncated or end < receipt.output.len;
        owned.output = try arena.dupe(u8, receipt.output[0..end]);
        if (self.recent.items.len == 8) _ = self.recent.orderedRemove(0);
        try self.recent.append(arena, owned);
    }

    pub fn observe(self: *State, arena: Allocator, cwd: []const u8, call: ToolCall, result: ExecResult) !void {
        if (!shell.isFamily(call.name)) return;
        const raw = shell.runCommand(call) orelse return;
        if (!isCheck(raw)) return;
        try self.observeKnown(arena, cwd, cwd, raw, result);
    }

    fn observeKnown(self: *State, arena: Allocator, cwd: []const u8, repository: []const u8, raw: []const u8, result: ExecResult) !void {
        const command = std.mem.trim(u8, raw, " \t\r\n");
        const backgrounded = result.pending or std.mem.indexOf(u8, result.text, "[job ") != null;
        const job: ?u64 = if (backgrounded and !result.is_error and !result.cancelled) jobIdIn(result.text) else null;
        for (self.failed.items, 0..) |*entry, i| {
            if (!std.mem.eql(u8, entry.cwd, cwd) or !std.mem.eql(u8, entry.command, command)) continue;
            if (!result.is_error and !result.cancelled and !backgrounded)
                _ = self.failed.orderedRemove(i)
            else
                entry.job = job;
            return;
        }
        if (!result.is_error and !result.cancelled and !backgrounded) return;
        try self.failed.append(arena, .{ .cwd = try arena.dupe(u8, cwd), .command = try arena.dupe(u8, command), .repository = try arena.dupe(u8, repository), .job = job });
    }

    pub fn write(self: *const State, writer: anytype) !void {
        try writer.objectField("publication_failed_checks");
        try writer.write(self.failed.items);
        try writer.objectField("publication_recent_checks");
        try writer.write(self.recent.items);
    }

    pub fn mixFingerprint(self: *const State, fingerprint: anytype) void {
        fingerprint.num(self.failed.items.len);
        for (self.failed.items) |entry| {
            fingerprint.text(entry.cwd);
            fingerprint.text(entry.command);
            fingerprint.text(entry.repository orelse entry.cwd);
        }
        fingerprint.num(self.recent.items.len);
        for (self.recent.items) |receipt| {
            fingerprint.text(receipt.repository);
            fingerprint.text(receipt.command);
            fingerprint.text(receipt.head_after);
            fingerprint.text(receipt.output);
            fingerprint.num(@intFromBool(receipt.tracked_tree_clean_after));
            fingerprint.num(@intFromBool(receipt.failed));
            fingerprint.num(@intFromBool(receipt.completed));
            fingerprint.num(@intFromBool(receipt.command_truncated));
            fingerprint.num(@intFromBool(receipt.output_truncated));
        }
    }

    pub fn restore(self: *State, arena: Allocator, object: std.json.ObjectMap) !void {
        var restored: State = .{};
        const saved = object.get("publication_failed_checks") orelse .null;
        if (saved != .null and saved != .array) return error.InvalidPublicationChecks;
        if (saved == .array) for (saved.array.items) |item| {
            if (item != .object) return error.InvalidPublicationChecks;
            const cwd = item.object.get("cwd") orelse return error.InvalidPublicationChecks;
            const command = item.object.get("command") orelse return error.InvalidPublicationChecks;
            if (cwd != .string or command != .string or !std.fs.path.isAbsolute(cwd.string) or command.string.len == 0)
                return error.InvalidPublicationChecks;
            const repository = item.object.get("repository") orelse .null;
            if (repository != .null and (repository != .string or !std.fs.path.isAbsolute(repository.string)))
                return error.InvalidPublicationChecks;
            try restored.failed.append(arena, .{ .cwd = try arena.dupe(u8, cwd.string), .command = try arena.dupe(u8, command.string), .repository = if (repository == .string) try arena.dupe(u8, repository.string) else null });
        };
        const receipts = object.get("publication_recent_checks") orelse .null;
        if (receipts != .null and receipts != .array) return error.InvalidPublicationChecks;
        if (receipts == .array) {
            if (receipts.array.items.len > 8) return error.InvalidPublicationChecks;
            for (receipts.array.items) |item| {
                if (item != .object) return error.InvalidPublicationChecks;
                const repository = item.object.get("repository") orelse return error.InvalidPublicationChecks;
                const command = item.object.get("command") orelse return error.InvalidPublicationChecks;
                const head = item.object.get("head_after") orelse return error.InvalidPublicationChecks;
                const output = item.object.get("output") orelse return error.InvalidPublicationChecks;
                const clean = item.object.get("tracked_tree_clean_after") orelse return error.InvalidPublicationChecks;
                const failed = item.object.get("failed") orelse return error.InvalidPublicationChecks;
                const completed = item.object.get("completed") orelse return error.InvalidPublicationChecks;
                const command_truncated = item.object.get("command_truncated") orelse std.json.Value{ .bool = false };
                const truncated = item.object.get("output_truncated") orelse return error.InvalidPublicationChecks;
                if (repository != .string or !std.fs.path.isAbsolute(repository.string) or command != .string or command.string.len == 0 or command.string.len > 1024 or head != .string or head.string.len > 64 or output != .string or output.string.len > 4096 or clean != .bool or failed != .bool or completed != .bool or command_truncated != .bool or truncated != .bool) return error.InvalidPublicationChecks;
                try restored.recordReceipt(arena, .{ .repository = repository.string, .command = command.string, .head_after = head.string, .tracked_tree_clean_after = clean.bool, .output = output.string, .failed = failed.bool, .completed = completed.bool, .command_truncated = command_truncated.bool, .output_truncated = truncated.bool });
            }
        }
        self.* = restored;
    }

    pub fn unresolved(self: *const State, cwd: []const u8) ?[]const u8 {
        for (self.failed.items) |entry| if (std.mem.eql(u8, entry.repository orelse entry.cwd, cwd)) return entry.command;
        return null;
    }
};

test "observed failed check survives unrelated success and clears only on its successful rerun" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"command\":\"python3 -m unittest test_delete -v\"}", .{});
    const call: ToolCall = .{ .id = "test", .name = "bash", .input = input };
    try state.observe(a, "/fixture", call, .{ .text = "FAIL", .is_error = true });
    try std.testing.expect(state.unresolved("/fixture") != null);
    try std.testing.expect(state.unresolved("/other") == null);
    const unrelated = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"command\":\"git diff\"}", .{});
    try state.observe(a, "/fixture", .{ .id = "inspect", .name = "bash", .input = unrelated }, .{ .text = "", .is_error = false });
    try std.testing.expect(state.unresolved("/fixture") != null);
    try state.observe(a, "/fixture", call, .{ .text = "[job 1 started]", .is_error = false });
    try std.testing.expect(state.unresolved("/fixture") != null);
    try state.observe(a, "/fixture", call, .{ .text = "exit 0", .is_error = false, .pending = true });
    try std.testing.expect(state.unresolved("/fixture") != null);
    try state.observe(a, "/fixture", call, .{ .text = "OK", .is_error = false });
    try std.testing.expect(state.unresolved("/fixture") == null);
}

test "check classification excludes prose and ordinary inspection" {
    try std.testing.expect(isCheck("python3 -m unittest test_delete -v"));
    try std.testing.expect(isCheck("zig build test"));
    try std.testing.expect(isCheck("cd apps/native && bun run test:desktop"));
    try std.testing.expect(isCheck("scripts/eval-tier1.sh --only reach"));
    try std.testing.expect(isCheck("SDKROOT=/fixture bun run test:desktop"));
    try std.testing.expect(isCheck("node scripts/test-motion.mjs /fixture --effort-only"));
    try std.testing.expect(isCheck("bun run build"));
    try std.testing.expect(isCheck("env CI=1 npm run typecheck"));
    try std.testing.expect(!isCheck("echo pytest failed"));
    try std.testing.expect(!isCheck("git diff"));
}

test "publication receipts record successful shell checks at the observed Git head" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    const ev = @import("pr_evidence.zig");
    const target: ev.Target = .{ .cwd = cwd, .selector = "" };
    _ = try ev.capture(std.testing.allocator, io, a, target, &.{ "git", "init", "-q" });
    _ = try ev.capture(std.testing.allocator, io, a, target, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "base" });
    const head = try ev.localHead(std.testing.allocator, io, a, target);
    var root: @import("agent.zig").Agent = undefined;
    root.gpa = std.testing.allocator;
    root.arena = a;
    root.io = io;
    root.sub = false;
    root.agent_cwd = cwd;
    root.publication_checks = .{};
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"run\",\"command\":\"node scripts/test-motion.mjs\"}", .{});
    const call: ToolCall = .{ .id = "check", .name = "shell", .input = input };
    try record(&root, call, .{ .text = "rendered dimensions passed", .is_error = false });
    try std.testing.expectEqual(@as(usize, 1), root.publication_checks.recent.items.len);
    const receipt = root.publication_checks.recent.items[0];
    try std.testing.expectEqualStrings(head, receipt.head_after);
    try std.testing.expectEqualStrings("rendered dimensions passed", receipt.output);
    try std.testing.expect(receipt.tracked_tree_clean_after and receipt.completed and !receipt.failed);
    const repository = try repositoryRoot(&root, cwd);
    try record(&root, call, .{ .text = "FAIL", .is_error = true });
    try std.testing.expect(root.publication_checks.unresolved(repository) != null);
    try record(&root, call, .{ .text = "passed", .is_error = false });
    try std.testing.expect(root.publication_checks.unresolved(repository) == null);
    const output = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"output\",\"command\":\"node scripts/test-motion.mjs\"}", .{});
    try record(&root, .{ .id = "poll", .name = "shell", .input = output }, .{ .text = "passed", .is_error = false });
    try std.testing.expectEqual(@as(usize, 3), root.publication_checks.recent.items.len);
}

test "failed checks survive serialization and malformed state is not a clean resume" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var original: State = .{};
    try original.failed.append(a, .{ .cwd = "/fixture", .command = "zig build test" });
    try original.recordReceipt(a, .{ .repository = "/fixture", .command = "zig build test", .head_after = "head", .tracked_tree_clean_after = true, .output = "1 test passed", .failed = false, .completed = true });
    var output: std.Io.Writer.Allocating = .init(a);
    var writer: std.json.Stringify = .{ .writer = &output.writer };
    try writer.beginObject();
    try original.write(&writer);
    try writer.endObject();
    const saved = try std.json.parseFromSliceLeaky(std.json.Value, a, output.writer.buffered(), .{});
    var resumed: State = .{};
    try resumed.restore(a, saved.object);
    try std.testing.expectEqualStrings("zig build test", resumed.unresolved("/fixture").?);
    try std.testing.expectEqual(@as(usize, 1), resumed.recent.items.len);
    try std.testing.expectEqualStrings("1 test passed", resumed.recent.items[0].output);
    const malformed = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"publication_failed_checks\":false}", .{});
    try std.testing.expectError(error.InvalidPublicationChecks, resumed.restore(a, malformed.object));
    try std.testing.expect(resumed.unresolved("/fixture") != null);
}

test "a sibling directory success cannot clear a failed worktree check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    try state.observeKnown(a, "/repo/one", "/repo", "pytest", .{ .text = "FAIL", .is_error = true });
    try state.observeKnown(a, "/repo/two", "/repo", "pytest", .{ .text = "OK", .is_error = false });
    try std.testing.expect(state.unresolved("/repo") != null);
    try std.testing.expect(state.unresolved("/another-repo") == null);
    try state.observeKnown(a, "/repo/one", "/repo", "pytest", .{ .text = "OK", .is_error = false });
    try std.testing.expect(state.unresolved("/repo") == null);
}

test "claim review local receipts retain bounded owned output and explicit limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: State = .{};
    var text: [4100]u8 = @splat('x');
    for (0..10) |_| try state.recordReceipt(arena.allocator(), .{ .repository = "/repo", .command = &text, .head_after = "head", .tracked_tree_clean_after = false, .output = &text, .failed = false, .completed = false });
    text[0] = 'y';
    try std.testing.expectEqual(@as(usize, 8), state.recent.items.len);
    const last = state.recent.items[7];
    try std.testing.expectEqual(@as(u8, 'x'), last.output[0]);
    try std.testing.expectEqual(@as(usize, 4096), last.output.len);
    try std.testing.expectEqual(@as(usize, 1024), last.command.len);
    try std.testing.expect(last.command_truncated);
    try std.testing.expect(last.output_truncated);
    try std.testing.expect(!last.completed and !last.tracked_tree_clean_after);
}

test "a check promoted to the background resolves when its job exits 0 (#1326)" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    const ev = @import("pr_evidence.zig");
    const target: ev.Target = .{ .cwd = cwd, .selector = "" };
    _ = try ev.capture(std.testing.allocator, io, a, target, &.{ "git", "init", "-q" });
    _ = try ev.capture(std.testing.allocator, io, a, target, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "base" });
    var root: @import("agent.zig").Agent = undefined;
    root.gpa = std.testing.allocator;
    root.arena = a;
    root.io = io;
    root.sub = false;
    root.agent_cwd = cwd;
    root.publication_checks = .{};
    const repository = try repositoryRoot(&root, cwd);
    const run = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"run\",\"command\":\"zig build test\"}", .{});
    const read = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"output\",\"id\":424242,\"wait_ms\":60000}", .{});

    // Output read: a nonzero exit keeps it unresolved, exit 0 resolves it.
    try record(&root, .{ .id = "run", .name = "shell", .input = run }, .{ .text = "[job 424242 started: zig build test]\nCommand exceeded the 120s foreground wait", .is_error = false, .pending = true });
    try std.testing.expect(root.publication_checks.unresolved(repository) != null);
    try record(&root, .{ .id = "read", .name = "shell", .input = read }, .{ .text = "[job 424242: exited with code 1]\nfailed", .is_error = true });
    try std.testing.expect(root.publication_checks.unresolved(repository) != null);
    try record(&root, .{ .id = "run2", .name = "shell", .input = run }, .{ .text = "[job 424243 started: zig build test]", .is_error = false, .pending = true });
    const reread = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"action\":\"output\",\"id\":424243}", .{});
    try record(&root, .{ .id = "read2", .name = "shell", .input = reread }, .{ .text = "[job 424243: exited with code 0]\nAll 3 tests passed.", .is_error = false });
    try std.testing.expect(root.publication_checks.unresolved(repository) == null);
    const receipt = root.publication_checks.recent.items[root.publication_checks.recent.items.len - 1];
    try std.testing.expect(receipt.completed and !receipt.failed);
    try std.testing.expectEqualStrings("zig build test", receipt.command);

    // Never read: the publication gate consults the job's recorded exit.
    try record(&root, .{ .id = "run3", .name = "shell", .input = run }, .{ .text = "[job 424244 started: zig build test]", .is_error = false, .pending = true });
    try std.testing.expect(root.publication_checks.unresolved(repository) != null);
    const job_notify = @import("job_notify.zig");
    job_notify.queue(io, 424244, 0, false, "zig build test", false, "ok");
    try resolveFinishedJobs(&root);
    try std.testing.expect(root.publication_checks.unresolved(repository) == null);
    job_notify.dismiss(io, 424244);
}
