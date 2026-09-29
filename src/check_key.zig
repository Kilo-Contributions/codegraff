//! #1375: one local check, one key, whichever toolchain ran it. A rerun that
//! only selects a different toolchain (`PATH=…`, `RUSTUP_TOOLCHAIN=…`,
//! `cargo +nightly`, another `zig` by absolute path) is the same check, so its
//! success resolves the earlier failure. The caller still matches directory
//! and repository; nothing here lets a rerun resolve a failure elsewhere.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Environment variables that only choose which toolchain runs.
const selectors = [_][]const u8{ "PATH", "RUSTUP_TOOLCHAIN", "GOTOOLCHAIN", "PYENV_VERSION", "UV_PYTHON", "NODE_VERSION", "DEVELOPER_DIR", "JAVA_HOME", "ZIG" };

/// Programs whose directory is a toolchain choice, not part of the check.
const tools = [_][]const u8{ "zig", "cargo", "rustc", "go", "node", "bun", "deno", "npm", "npx", "pnpm", "yarn", "python", "python3", "pytest", "make" };

fn isSelectorAssignment(word: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    for (selectors) |name| if (std.mem.eql(u8, word[0..eq], name)) return true;
    return false;
}

fn skipSpace(command: []const u8, from: usize) usize {
    var i = from;
    while (i < command.len and (command[i] == ' ' or command[i] == '\t')) i += 1;
    return i;
}

/// End of the shell word at `from`: quotes, escapes and `$(…)` keep it whole.
fn wordEnd(command: []const u8, from: usize) usize {
    var i = from;
    var quote: u8 = 0;
    var depth: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (quote == '\'') {
            if (c == '\'') quote = 0;
        } else if (c == '\\') {
            i += 1;
        } else if (c == '$' and i + 1 < command.len and command[i + 1] == '(') {
            depth += 1;
            i += 1;
        } else if (depth > 0 and c == ')') {
            depth -= 1;
        } else if (quote == '"') {
            if (c == '"') quote = 0;
        } else if (c == '\'' or c == '"') {
            quote = c;
        } else if (depth == 0 and std.ascii.isWhitespace(c)) return i;
    }
    return command.len;
}

/// Where the checked program's words begin: after one leading `cd DIR &&`,
/// the only prefix pr_command.literal keeps as the working directory.
fn programStart(command: []const u8) usize {
    const start = skipSpace(command, 0);
    const cd_end = wordEnd(command, start);
    if (!std.mem.eql(u8, command[start..cd_end], "cd")) return start;
    const amp = skipSpace(command, wordEnd(command, skipSpace(command, cd_end)));
    return if (std.mem.startsWith(u8, command[amp..], "&& ")) amp + 3 else start;
}

/// `command` without `env` and toolchain-selection assignments in front of
/// the program, so a dynamic value (`PATH="$HOME/zig:$PATH"`) no longer makes
/// the whole command unobservable.
pub fn stripSelectors(a: Allocator, command: []const u8) ![]const u8 {
    const start = programStart(command);
    var at = skipSpace(command, start);
    var first = true;
    while (at < command.len) : (first = false) {
        const end = wordEnd(command, at);
        const word = command[at..end];
        if (!(first and std.mem.eql(u8, word, "env")) and !isSelectorAssignment(word)) break;
        at = skipSpace(command, end);
    }
    if (at == skipSpace(command, start)) return command;
    return std.mem.concat(a, u8, &.{ command[0..start], command[at..] });
}

/// The check's key: its argv, with a known toolchain program reduced to its
/// name and rustup's `+toolchain` argument dropped.
pub fn key(a: Allocator, argv: []const []const u8) ![]const u8 {
    var words = argv;
    if (words.len > 1 and std.mem.eql(u8, words[0], "env")) words = words[1..];
    if (words.len == 0) return "";
    const name = std.fs.path.basename(words[0]);
    const known = for (tools) |tool| {
        if (std.mem.eql(u8, name, tool)) break true;
    } else false;
    var rest = words[1..];
    const rustup = std.mem.eql(u8, name, "cargo") or std.mem.eql(u8, name, "rustc");
    if (known and rustup and rest.len > 0 and rest[0].len > 1 and rest[0][0] == '+') rest = rest[1..];
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, if (known) name else words[0]);
    try out.appendSlice(a, rest);
    return std.mem.join(a, " ", out.items);
}

fn keyOf(a: Allocator, command: []const u8) ![]const u8 {
    const parsed = try @import("pr_command.zig").literal(a, try stripSelectors(a, command));
    return key(a, parsed.argv);
}

test "#1375: a toolchain-only difference is the same check; anything else is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "zig build test",
        "PATH=/opt/zig-0.17/bin:/usr/bin zig build test",
        "PATH=\"$HOME/.local/zig:$PATH\" zig build test",
        "env PATH=$(dirname $(command -v zig)):$PATH ZIG=/opt/zig zig build test",
        "/Users/fixture/.local/share/zigup/0.17/files/zig build test",
    }) |spelling| try std.testing.expectEqualStrings("zig build test", try keyOf(a, spelling));
    try std.testing.expectEqualStrings("cargo test --workspace", try keyOf(a, "RUSTUP_TOOLCHAIN=nightly cargo +nightly test --workspace"));
    // The directory prefix survives for the caller to resolve.
    const in_app = try @import("pr_command.zig").literal(a, try stripSelectors(a, "cd app && PATH=\"$X:$PATH\" zig build test"));
    try std.testing.expectEqualStrings("app", in_app.cwd.?);
    try std.testing.expectEqualStrings("zig build test", try key(a, in_app.argv));
    // Settings that change what the check does stay in the key.
    try std.testing.expectEqualStrings("SKIP_SLOW=1 zig build test", try keyOf(a, "SKIP_SLOW=1 zig build test"));
    try std.testing.expectEqualStrings("zig build test -Dtest-filter=x", try keyOf(a, "zig build test -Dtest-filter=x"));
    try std.testing.expectEqualStrings("./run-tests.sh", try keyOf(a, "./run-tests.sh"));
    // A dynamic value outside the toolchain selection is still unobservable.
    try std.testing.expectError(error.DynamicCommand, keyOf(a, "FILTER=$X zig build test"));
}
