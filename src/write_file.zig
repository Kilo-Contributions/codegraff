//! write_file (ADR 0231). Creates a file, or replaces one this session has
//! already read, edited or written; replacing any other existing file takes
//! `replace: true`. The guard is what lets a model write a new file straight
//! away: without it a careful model spent a whole round trip checking that the
//! path was free. The result says what happened (created or replaced, and for
//! a .json path whether the content parses), so a successful write needs no
//! read-back either.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const approvals = @import("approvals.zig");
const codedbpro_paths = @import("codedbpro_paths.zig");
const edit_verify = @import("edit_verify.zig");

const page = std.heap.page_allocator;

/// Absolute paths whose content this process has seen. Process-wide, so a
/// subagent's read counts for its parent and the other way round.
var known: std.StringHashMapUnmanaged(void) = .empty;
var known_lock: std.atomic.Value(bool) = .init(false);

fn lock() void {
    while (known_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    known_lock.store(false, .release);
}

pub fn noteKnown(abs_path: []const u8) void {
    lock();
    defer unlock();
    if (known.contains(abs_path)) return;
    const key = page.dupe(u8, abs_path) catch return;
    known.put(page, key, {}) catch page.free(key);
}

fn isKnown(abs_path: []const u8) bool {
    lock();
    defer unlock();
    return known.contains(abs_path);
}

/// After a successful read_file or edit_file: the model has seen this path.
pub fn noteInput(ctx: tools.ToolCtx, input: std.json.Value) void {
    const path = tools.strField(input, "path") orelse return;
    const resolved = codedbpro_paths.sessionAbs(ctx.gpa, ctx.io, ctx.agent_cwd, path) catch return;
    defer ctx.gpa.free(resolved);
    noteKnown(resolved);
}

pub fn exec(ctx: tools.ToolCtx, input: std.json.Value) !tools.ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const path = tools.strField(input, "path") orelse return tools.missingArg(gpa, "path");
    const content = tools.strField(input, "content") orelse return tools.missingArg(gpa, "content");
    if (!approvals.confinedPath(path) or !approvals.noSymlinkEscape(io, path, ctx.agent_cwd)) return tools.outsideCwd(gpa, path);
    // #747: share sessionAbs with edit_file so a write cannot land in
    // posix cwd while the next edit looks at a stale display cwd.
    const resolved = try codedbpro_paths.sessionAbs(gpa, io, ctx.agent_cwd, path);
    defer gpa.free(resolved);
    // #337: a write_file racing an edit_file on the same path in the same
    // assistant turn (agent_tools.zig runs them concurrently) would drop
    // one of the two. Same stripe as edit_file, so they take turns.
    const path_lock = edit_verify.lockPath(io, resolved);
    defer path_lock.unlock(io);
    // #179: an existing file keeps its mode (e.g. 0755) across the overwrite;
    // a brand-new file (prev_stat == null) keeps the default.
    const prev_stat = Io.Dir.cwd().statFile(io, resolved, .{}) catch null;
    if (prev_stat) |st| if (st.kind == .file and st.size > 0 and !isKnown(resolved) and !tools.json_args.flag(input, "replace")) return .{
        .text = try std.fmt.allocPrint(gpa, "{s} already exists ({d} bytes) and has not been read in this session; nothing was written. Read it first, or pass replace: true to overwrite it.", .{ path, st.size }),
        .is_error = true,
    };
    if (ctx.snapshots) |snaps| if (!ctx.from_sub) {
        // capture the prior content (or absence) before overwriting, for /rewind.
        // beforeFromRead keeps a merely UNREADABLE file (over the cap, permissions)
        // distinct from a missing one — only the latter is a rewind-deletes-it.
        const before = tools.beforeFromRead(Io.Dir.cwd().readFileAlloc(io, resolved, gpa, .limited(4 * 1024 * 1024)));
        defer if (before == .content) gpa.free(before.content);
        snaps.record(path, before);
    };
    const made_dir = writeCreating(io, resolved, content, prev_stat == null) catch |err| {
        if (edit_verify.fsErrorText(gpa, .write, path, err)) |t| return .{ .text = t, .is_error = true };
        return err;
    };
    edit_verify.preserveMode(io, resolved, prev_stat);
    noteKnown(resolved);
    const dir = if (made_dir) std.fs.path.dirname(path) else null;
    return .{ .text = try resultText(gpa, path, content, if (prev_stat) |st| st.size else null, dir) };
}

/// A new file whose directory is missing gets the directory first, as
/// `mkdir -p` would. Refusing it cost the model a second generation of the
/// whole content, which is most of what a large write costs. True when the
/// directory was made.
fn writeCreating(io: Io, resolved: []const u8, data: []const u8, new_file: bool) !bool {
    Io.Dir.cwd().writeFile(io, .{ .sub_path = resolved, .data = data }) catch |err| {
        if (err != error.FileNotFound or !new_file) return err;
        const parent = std.fs.path.dirname(resolved) orelse return err;
        try Io.Dir.cwd().createDirPath(io, parent);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = resolved, .data = data });
        return true;
    };
    return false;
}

fn resultText(gpa: Allocator, path: []const u8, content: []const u8, prev_size: ?u64, made_dir: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    if (prev_size) |was| {
        try w.print("replaced {s} ({d} bytes; was {d})", .{ path, content.len, was });
    } else try w.print("created {s} ({d} bytes)", .{ path, content.len });
    if (made_dir) |d| try w.print(" in new directory {s}", .{d});
    if (std.ascii.endsWithIgnoreCase(path, ".json")) try jsonNote(gpa, w, content);
    return out.toOwnedSlice();
}

/// A generated data file is the usual thing a model re-opens to check, so
/// the parse result rides the write's own result.
fn jsonNote(gpa: Allocator, w: *std.Io.Writer, content: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(gpa, content);
    defer scanner.deinit();
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    while (true) {
        const token = scanner.next() catch |err| {
            if (err == error.OutOfMemory) return;
            return w.print("; NOT valid JSON ({t} at line {d}, column {d})", .{ err, diag.getLine(), diag.getColumn() });
        };
        if (token == .end_of_document) return w.writeAll("; parses as JSON");
    }
}

test "write_file creates, refuses to clobber an unread file, and replaces a known one (ADR 0231)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // same write path as the /rewind tests, which skip there too
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const out_json = try std.fmt.allocPrint(a, "{s}/out.json", .{dir});
    const theirs = try std.fmt.allocPrint(a, "{s}/theirs.txt", .{dir});
    var client: std.http.Client = undefined;
    const ctx: tools.ToolCtx = .{ .gpa = gpa, .io = io, .client = &client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };

    var args: std.json.ObjectMap = .empty;
    try args.put(a, "path", .{ .string = out_json });
    try args.put(a, "content", .{ .string = "{\"n\": 1}" });
    const created = try exec(ctx, .{ .object = args });
    defer gpa.free(created.text);
    try std.testing.expect(!created.is_error);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "created {s} (8 bytes); parses as JSON", .{out_json}), created.text);

    // A file this session never saw is refused and left untouched.
    try tmp.dir.writeFile(io, .{ .sub_path = "theirs.txt", .data = "keep me" });
    args.getPtr("path").?.* = .{ .string = theirs };
    args.getPtr("content").?.* = .{ .string = "{\"n\": " };
    const refused = try exec(ctx, .{ .object = args });
    defer gpa.free(refused.text);
    try std.testing.expect(refused.is_error);
    const kept = try tmp.dir.readFileAlloc(io, "theirs.txt", gpa, .limited(64));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("keep me", kept);

    // replace: true overwrites it; a file this session wrote needs no flag.
    try args.put(a, "replace", .{ .bool = true });
    const replaced = try exec(ctx, .{ .object = args });
    defer gpa.free(replaced.text);
    try std.testing.expect(!replaced.is_error);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "replaced {s} (6 bytes; was 7)", .{theirs}), replaced.text);
    _ = args.swapRemove("replace");
    args.getPtr("path").?.* = .{ .string = out_json };
    const again = try exec(ctx, .{ .object = args });
    defer gpa.free(again.text);
    try std.testing.expect(!again.is_error);
    try std.testing.expect(std.mem.startsWith(u8, again.text, try std.fmt.allocPrint(a, "replaced {s} (6 bytes; was 8); NOT valid JSON (", .{out_json})));

    // A new file in a missing directory gets the directory, not a refusal
    // the model answers by generating the whole content again.
    const nested = try std.fmt.allocPrint(a, "{s}/docs/deep/FORMAT.md", .{dir});
    args.getPtr("path").?.* = .{ .string = nested };
    args.getPtr("content").?.* = .{ .string = "# x\n" };
    const made = try exec(ctx, .{ .object = args });
    defer gpa.free(made.text);
    try std.testing.expect(!made.is_error);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "created {s} (4 bytes) in new directory {s}/docs/deep", .{ nested, dir }), made.text);
    const landed = try tmp.dir.readFileAlloc(io, "docs/deep/FORMAT.md", gpa, .limited(64));
    defer gpa.free(landed);
    try std.testing.expectEqualStrings("# x\n", landed);
}
