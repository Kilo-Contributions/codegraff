//! Launch the separately installed fullscreen client before engine startup.
const std = @import("std");
const builtin = @import("builtin");

const binary_name = if (builtin.os.tag == .windows) "graff-tui.exe" else "graff-tui";

/// Inspect raw arguments so UI flags (including --help) never reach graff's
/// parser. `graff -p "tui"` remains a normal prompt.
pub fn maybeRun(init: std.process.Init) !bool {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();
    const command = it.next() orelse return false;
    if (!std.mem.eql(u8, command, "tui")) return false;

    const a = init.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, binary_name);
    while (it.next()) |arg| try argv.append(a, arg);

    // Prefer the companion shipped alongside this executable, then PATH.
    // Do not fetch a binary or initialize credentials, MCP, or a session.
    if (std.process.executableDirPathAlloc(init.io, a) catch null) |dir| {
        argv.items[0] = try std.fs.path.join(a, &.{ dir, binary_name });
        launch(init.io, argv.items) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.process.fatal("cannot launch {s}: {s}", .{ binary_name, @errorName(err) }),
        };
    }
    argv.items[0] = binary_name;
    launch(init.io, argv.items) catch |err| switch (err) {
        error.FileNotFound => std.process.fatal("{s} is not installed. Install the separate TUI next to graff or on PATH. No files were downloaded.", .{binary_name}),
        else => std.process.fatal("cannot launch {s}: {s}", .{ binary_name, @errorName(err) }),
    };
    unreachable;
}

fn launch(io: std.Io, argv: []const []const u8) !void {
    // POSIX replacement preserves the terminal, process identity, signals,
    // and exit status. Windows has no exec; inherit its handles and wait.
    if (builtin.os.tag != .windows) return std.process.replace(io, .{ .argv = argv });
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}
