//! GRAFF_COMPACT_MIX — two-pass "mixture" compaction, experimental arm for the
//! #compact-ab comparison (`evals/compact_ab`).
//!
//! The measured failure of single-pass compaction is NOT prose quality: it is
//! state loss — the exact line in flight, the approach already ruled out, the
//! identifier the next turn needs verbatim (see compact_note.zig #391 and the
//! compact_ab README's retry-loop observation). A single summary request is
//! asked to both DISCOVER that state and narrate it; a summarizer optimizes for
//! a readable account and drops exactly the details a working agent cannot
//! cheaply re-derive.
//!
//! The mixture separates the two jobs across two passes with different effort:
//!
//!   PASS 1 — EXTRACT (pinned low effort, "Jev-low"): pull a terse state ledger
//!   out of the history — decisions, dead ends (with WHY), in-flight identifiers
//!   and numbers VERBATIM, the next step, open user asks. Mechanical work; a
//!   cheap pass is the right tool and low effort cannot "complete with only
//!   reasoning items" (#379's failure) because the ledger is the output.
//!
//!   PASS 2 — SYNTHESIS (session effort, i.e. whatever /effort or the jev_effort
//!   tool selected): the normal handoff summary, with the ledger injected as a
//!   checklist the summary must carry. The synthesis request is otherwise the
//!   exact request compact() sends today, so the #379 completeness/empty checks
//!   and the transactional history restore keep working unchanged.
//!
//! Any extract failure (transport, empty, incomplete) is a NAMED SKIP: the
//! ledger is null and pass 2 runs the byte-identical single-pass summary
//! request. The arm can therefore never be worse than the baseline in failure
//! behavior — only in cost (one extra low-effort call per compaction).
//!
//! Effort routing detail: the Responses body writer forces `low` on compaction
//! requests (agent_request_body_responses.zig, #379). During pass 1 that is
//! exactly what we want. During pass 2 `synthSessionEffort()` lifts the force
//! so the session's Jev-selected effort applies; the empty/incomplete guards
//! remain and the compact_ab comparison prices the trade.
//!
//! ADR 0002 / standing rule: this is a CLIENT summarizer path. grok/xAI
//! compaction stays on it — never xAI's first-party compact endpoint.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Agent = @import("agent.zig").Agent;
const messages_mod = @import("messages.zig");
const title_mod = @import("title.zig");
const util = @import("util.zig");

/// Which mixture pass owns the current request. Set around each internal
/// request by extractLedger() / compact(); `.none` is the steady state.
pub const Pass = enum { none, extract, synth };

pub var g_enabled: bool = false; // GRAFF_COMPACT_MIX (session_settings.applyEnvKnobs)
pub var g_pass: Pass = .none;

pub fn enabled() bool {
    return g_enabled;
}

pub fn inExtract() bool {
    return g_pass == .extract;
}

/// True when the Responses body writer should NOT force low effort: the
/// synthesis pass of an enabled mixture runs at the session's effort.
pub fn synthSessionEffort() bool {
    return g_enabled and g_pass == .synth;
}

/// Ledger ceiling (~500 tokens): a compaction runs where context is scarce, so
/// the ledger is a checklist, not a second summary.
pub const max_ledger_bytes: usize = 2048;

pub fn capLedger(text: []const u8) []const u8 {
    return util.utf8Prefix(text, max_ledger_bytes);
}

pub fn extractPrompt() []const u8 {
    return
    \\[state-extraction pass — internal, no tools, output the ledger ONLY]
    \\Extract a terse STATE LEDGER from the conversation above. Answer with only
    \\the ledger, exactly these five lines, one section per line, no preamble:
    \\DECISIONS: what was decided and why
    \\DEAD ENDS: approaches tried and ruled out, each with the reason
    \\IN FLIGHT: identifiers, numbers, file paths and exact lines currently in use — VERBATIM
    \\NEXT: the immediate next step
    \\USER ASK: explicit user requests still open
    \\Copy every identifier, number and path character-for-character. Use "-" for
    \\an empty section. Never narrate; this is state, not a summary.
    ;
}

/// The synthesis request: today's summary request, plus the ledger as a
/// checklist the summary must carry. With a null ledger the base is returned
/// byte-identical, so the fallback path is exactly the single-pass request.
pub fn composeSummary(arena: Allocator, base: []const u8, ledger: ?[]const u8) ![]const u8 {
    const l = ledger orelse return base;
    return std.fmt.allocPrint(arena,
        \\{s}
        \\
        \\[state ledger, extracted from the same conversation by the preceding
        \\low-effort pass. Carry it into the summary as a checklist, not as text to
        \\paraphrase: every DEAD ENDS entry must survive as a ruled-out approach, IN
        \\FLIGHT values must survive character-for-character, and NEXT / USER ASK
        \\must be reflected in the unfinished-work section. Sections with "-" add
        \\nothing.]
        \\
        \\{s}
    , .{ base, l });
}

/// The summary request compact() sends. Off, it is the single-pass request;
/// on, pass 1 runs first (its exchange never enters history) and pass 2 gets
/// the ledger woven in.
pub fn summaryRequest(self: *Agent, arena: Allocator) ![]const u8 {
    const ledger: ?[]const u8 = if (g_enabled) try extractLedger(self, arena) else null;
    return composeSummary(arena, try @import("compact_handoff_note.zig").summaryRequest(arena, self), ledger);
}

/// PASS 2 is compact()'s own summary request, marked so the Responses body
/// writer runs it at session (Jev) effort when the arm is on.
pub fn synthRequest(self: *Agent, tools: ?[]const u8) !std.json.ObjectMap {
    g_pass = .synth;
    defer g_pass = .none;
    return self.request(tools);
}

/// PASS 1: run the extract request over the pending summary window
/// (`self.messages` already holds it). Best-effort by contract — every failure
/// is a named skip returning null, and the caller falls back to the
/// byte-identical single-pass summary. The extract exchange (prompt + any
/// reply request() appended) is popped before returning, so the history pass 2
/// sees is unchanged.
pub fn extractLedger(self: *Agent, arena: Allocator) !?[]const u8 {
    const agent_compact = @import("agent_compact.zig");
    const mark = self.messages.items.len;
    const was_quiet = self.stream_quiet;
    const was_compaction_request = self.compaction_request;
    const was_mutation_arena = self.message_mutation_arena;
    const was_reasoning = self.reasoning;
    defer {
        self.stream_quiet = was_quiet;
        self.compaction_request = was_compaction_request;
        self.message_mutation_arena = was_mutation_arena;
        self.reasoning = was_reasoning;
        g_pass = .none;
        self.messages.shrinkRetainingCapacity(mark); // scaffolding never enters history
    }
    try self.messages.append(try messages_mod.textMessage(arena, "user", extractPrompt()));
    // The extract prompt is the turn boundary for the same reasoning prune the
    // synthesis pass performs; running it here makes the later call a no-op.
    _ = agent_compact.dropPriorTurnReasoning(self);
    self.stream_quiet = true;
    self.compaction_request = true;
    self.message_mutation_arena = arena;
    self.reasoning = .low; // "Jev-low": mechanical extraction, chat and Responses wires alike
    g_pass = .extract;
    // A cache fork (ADR 0220) sends the conversation's own tools so this pass
    // reads the cached prefix too; otherwise none, like the summary request.
    const root = self.request(@import("cache_fork.zig").tools(self, @import("cache_fork.zig").shares())) catch return null;
    if (!agent_compact.summaryResponseComplete(self, root)) return null;
    const text = std.mem.trim(u8, title_mod.assistantText(self.provider.kind, root), " \t\r\n");
    if (text.len == 0) return null;
    return try arena.dupe(u8, capLedger(text));
}

test "composeSummary with no ledger is byte-identical to the single-pass request" {
    const a = std.testing.allocator;
    const base = "summarize the work";
    try std.testing.expectEqualStrings(base, try composeSummary(a, base, null));
}

test "composeSummary weaves the ledger in as a checklist" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try composeSummary(a, "BASE", "DECISIONS: keep the pin");
    try std.testing.expect(std.mem.indexOf(u8, out, "BASE") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DECISIONS: keep the pin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DEAD ENDS") != null); // the checklist contract
    try std.testing.expect(std.mem.indexOf(u8, out, "character-for-character") != null);
}

test "capLedger bounds the ledger at max_ledger_bytes on a UTF-8 boundary" {
    const small = capLedger("short");
    try std.testing.expectEqualStrings("short", small);
    var big: [max_ledger_bytes + 64]u8 = undefined;
    @memset(&big, 'x');
    try std.testing.expect(capLedger(&big).len <= max_ledger_bytes);
}

test "extractPrompt names all five ledger sections and demands verbatim values" {
    const p = extractPrompt();
    for ([_][]const u8{ "DECISIONS:", "DEAD ENDS:", "IN FLIGHT:", "NEXT:", "USER ASK:" }) |section|
        try std.testing.expect(std.mem.indexOf(u8, p, section) != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "VERBATIM") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "no tools") != null);
}

test "synthSessionEffort lifts forced-low only for a mixture synthesis pass" {
    const saved_enabled = g_enabled;
    const saved_pass = g_pass;
    defer {
        g_enabled = saved_enabled;
        g_pass = saved_pass;
    }
    g_enabled = false;
    g_pass = .synth;
    try std.testing.expect(!synthSessionEffort()); // flag off: behavior unchanged
    g_enabled = true;
    g_pass = .none;
    try std.testing.expect(!synthSessionEffort());
    g_pass = .extract;
    try std.testing.expect(!synthSessionEffort()); // pass 1 stays low
    try std.testing.expect(inExtract());
    g_pass = .synth;
    try std.testing.expect(synthSessionEffort());
}
