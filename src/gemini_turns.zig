//! ADR 0256: Gemini models finish a task in fewer model requests.
//!
//! On the hosted route each Gemini request carries the system prompt and the
//! tool catalog again, so a task's cost and wall time follow its request
//! count. Traces showed requests the work did not need: reading back a file
//! the model had just written, a separate request for a command that could
//! have chained onto the previous one, and a last request whose only call was
//! attempt_completion.
//!
//! For these models only:
//! - A working note asks for chained shell steps, no read-backs, and a final
//!   answer that names files instead of pasting them.
//! - attempt_completion may share a response with the last write or edit, as
//!   it already could with a final check. The harness runs the other calls
//!   first (a batch with a write runs serially, in the order sent) and records
//!   the completion only if every one of them succeeded, so the claim still
//!   follows evidence. The tool description says so.

const std = @import("std");

/// A Gemini model id, bare or behind a `vendor/` prefix.
pub fn family(model: []const u8) bool {
    const bare = model[if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| i + 1 else 0..];
    return std.ascii.startsWithIgnoreCase(bare, "gemini-");
}

/// Appended to the system prompt by prompt_guidance.append.
pub const note =
    \\
    \\# Working guidance
    \\Each model request takes seconds, so finish in as few responses as the work allows:
    \\- Run dependent shell steps as one command (`a && b`), cleanup of temporary files included; to write exact text from the shell use `printf`, not `echo -n`.
    \\- A write's own result is its evidence: do not read back or list a file you just wrote.
    \\- The final answer names the files and the key result; never paste a file's contents into it.
    \\- Call attempt_completion in the same response as your final check or write: the harness runs those first and records the completion only if they succeed.
    \\- Before you write a computed answer, check it against every condition the task states (exact tokens, exclusions, formats): print what matched, not only a count.
;

/// Added to attempt_completion's description on these models.
pub const completion_batch = " You may call it in the same response as your final check (a test run or other command): the harness runs that check first and records the completion only if it succeeds; if it fails you get its result instead. The same holds for a final write_file or edit_file when nothing after it needs checking: the completion is recorded only if the write succeeds.";

/// A rendered root catalog with attempt_completion's description extended
/// for this model (the shell_tool.withPython pattern). Other models, and a
/// catalog without the full description (lean), come back unchanged.
pub fn withCompletionBatch(arena: std.mem.Allocator, catalog: []const u8, model: []const u8) ![]const u8 {
    if (!family(model)) return catalog;
    const desc = @import("schema.zig").attempt_completion_desc;
    if (std.mem.indexOf(u8, catalog, desc) == null) return catalog;
    return std.mem.replaceOwned(u8, arena, catalog, desc, desc ++ completion_batch);
}

test "family matches Gemini ids with or without a vendor prefix, and nothing else" {
    for ([_][]const u8{ "gemini-3.8-flash", "gemini-3.7-flash", "google/gemini-3.1-pro-preview", "Gemini-3.8-Flash" }) |m|
        try std.testing.expect(family(m));
    for ([_][]const u8{ "gemma-3", "gpt-6-sol", "deepseek-v4-flash", "mimo-v2.6-flash", "my-gemini-proxy", "" }) |m|
        try std.testing.expect(!family(m));
}

test "only Gemini catalogs advertise a batched completion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const desc = @import("schema.zig").attempt_completion_desc;
    const catalog = try std.mem.concat(a, u8, &.{ "[{\"name\":\"attempt_completion\",\"description\":\"", desc, "\"}]" });
    const extended = try withCompletionBatch(a, catalog, "gemini-3.8-flash");
    try std.testing.expect(std.mem.indexOf(u8, extended, completion_batch) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, extended, desc));
    try std.testing.expect(std.json.validate(a, extended) catch false);
    try std.testing.expectEqualStrings(catalog, try withCompletionBatch(a, catalog, "gpt-6.1-sol"));
    try std.testing.expectEqualStrings("[]", try withCompletionBatch(a, "[]", "gemini-3.8-flash"));
}
