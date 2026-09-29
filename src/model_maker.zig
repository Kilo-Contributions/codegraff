//! Who made a model, as a stable slug for a client's logo (`graff/models`).
//!
//! The catalog keys a model by the route that serves it (`provider`) and its
//! name. The route is not the maker: `codegraff/claude-opus-5` is Anthropic's
//! model served by the Codegraff gateway, `groq/openai/gpt-oss-120b` is
//! OpenAI's. So the name decides first — a router's `vendor/model` prefix,
//! then the model family — and the provider only when the provider is itself
//! the lab. Unknown (local, custom, router-only) models get null, and a
//! client falls back to its own matching.

const std = @import("std");

const Rule = struct { key: []const u8, maker: []const u8 };

/// A router's `vendor/…` prefix (OpenRouter, Vercel, Groq, Fireworks slugs).
const vendor_prefixes = [_]Rule{
    .{ .key = "anthropic", .maker = "anthropic" }, .{ .key = "openai", .maker = "openai" },
    .{ .key = "google", .maker = "google" },       .{ .key = "x-ai", .maker = "xai" },
    .{ .key = "xai", .maker = "xai" },             .{ .key = "moonshotai", .maker = "moonshot" },
    .{ .key = "moonshot", .maker = "moonshot" },   .{ .key = "z-ai", .maker = "zai" },
    .{ .key = "zai", .maker = "zai" },             .{ .key = "zai-org", .maker = "zai" },
    .{ .key = "deepseek", .maker = "deepseek" },   .{ .key = "deepseek-ai", .maker = "deepseek" },
    .{ .key = "xiaomi", .maker = "xiaomi" },       .{ .key = "minimax", .maker = "minimax" },
    .{ .key = "mistralai", .maker = "mistral" },   .{ .key = "mistral", .maker = "mistral" },
    .{ .key = "alibaba", .maker = "alibaba" },     .{ .key = "qwen", .maker = "alibaba" },
    .{ .key = "meta", .maker = "meta" },           .{ .key = "meta-llama", .maker = "meta" },
};

/// The model family at the start of the bare name.
const families = [_]Rule{
    .{ .key = "claude", .maker = "anthropic" }, .{ .key = "gpt", .maker = "openai" },
    .{ .key = "o1", .maker = "openai" },        .{ .key = "o3", .maker = "openai" },
    .{ .key = "o4", .maker = "openai" },        .{ .key = "codex", .maker = "openai" },
    .{ .key = "gemini", .maker = "google" },    .{ .key = "gemma", .maker = "google" },
    .{ .key = "grok", .maker = "xai" },         .{ .key = "kimi", .maker = "moonshot" },
    .{ .key = "k2", .maker = "moonshot" },      .{ .key = "k3", .maker = "moonshot" },
    .{ .key = "glm", .maker = "zai" },          .{ .key = "deepseek", .maker = "deepseek" },
    .{ .key = "mimo", .maker = "xiaomi" },      .{ .key = "minimax", .maker = "minimax" },
    .{ .key = "mistral", .maker = "mistral" },  .{ .key = "codestral", .maker = "mistral" },
    .{ .key = "devstral", .maker = "mistral" }, .{ .key = "magistral", .maker = "mistral" },
    .{ .key = "qwen", .maker = "alibaba" },     .{ .key = "llama", .maker = "meta" },
    .{ .key = "muse", .maker = "meta" },
};

/// Providers that are the lab behind every model they serve.
const lab_providers = [_]Rule{
    .{ .key = "anthropic", .maker = "anthropic" }, .{ .key = "openai", .maker = "openai" },
    .{ .key = "codex", .maker = "openai" },        .{ .key = "google", .maker = "google" },
    .{ .key = "xai", .maker = "xai" },             .{ .key = "kimi", .maker = "moonshot" },
    .{ .key = "moonshot", .maker = "moonshot" },   .{ .key = "zai", .maker = "zai" },
    .{ .key = "deepseek", .maker = "deepseek" },   .{ .key = "xiaomi", .maker = "xiaomi" },
    .{ .key = "minimax", .maker = "minimax" },     .{ .key = "mistral", .maker = "mistral" },
    .{ .key = "meta", .maker = "meta" },
};

fn lookup(rules: []const Rule, key: []const u8) ?[]const u8 {
    for (rules) |r| if (std.ascii.eqlIgnoreCase(r.key, key)) return r.maker;
    return null;
}

/// The family is the name's leading word: up to the first `-`, `.`, `:`, `_`
/// or digit run boundary that ends a known family (`gpt-5.6` → gpt,
/// `o3-mini` → o3, `MiniMax-M3` → minimax).
fn family(bare: []const u8) ?[]const u8 {
    for (families) |r| {
        if (bare.len < r.key.len or !std.ascii.eqlIgnoreCase(bare[0..r.key.len], r.key)) continue;
        if (bare.len == r.key.len) return r.maker;
        const next = bare[r.key.len];
        if (next == '-' or next == '.' or next == ':' or next == '_' or next == ' ') return r.maker;
        // `gpt5`, `glm4`: a digit may follow a word family directly, but not a
        // bare-digit one (`o3` must not claim `o30x`, `k3` must not claim `k3s`).
        if (std.ascii.isDigit(next) and !std.ascii.isDigit(r.key[r.key.len - 1])) return r.maker;
    }
    return null;
}

pub fn of(provider: []const u8, name: []const u8) ?[]const u8 {
    var bare = name;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |last| {
        const first = std.mem.indexOfScalar(u8, name, '/').?;
        if (lookup(&vendor_prefixes, name[0..first])) |m| return m;
        bare = name[last + 1 ..]; // `accounts/fireworks/models/<model>`
    }
    if (family(bare)) |m| return m;
    return lookup(&lab_providers, provider);
}

const testing = std.testing;

fn expectMaker(expected: ?[]const u8, provider: []const u8, name: []const u8) !void {
    const got = of(provider, name);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else try testing.expect(got == null);
}

test "maker: the gateway serves other labs' models" {
    try expectMaker("anthropic", "codegraff", "claude-opus-5");
    try expectMaker("xiaomi", "codegraff", "mimo-v2.6-flash");
    try expectMaker("deepseek", "codegraff", "deepseek-v4-pro");
    try expectMaker("zai", "codegraff", "glm-5.3");
    try expectMaker("moonshot", "codegraff", "kimi-k3");
    try expectMaker("xai", "codegraff", "grok-4.7");
    try expectMaker("minimax", "codegraff", "minimax-m3");
    try expectMaker("openai", "codegraff", "gpt-5.6-sol");
    try expectMaker("meta", "codegraff", "muse-spark");
}

test "maker: routers' vendor prefixes and nested slugs" {
    try expectMaker("anthropic", "openrouter", "anthropic/claude-sonnet-5");
    try expectMaker("openai", "groq", "openai/gpt-oss-120b");
    try expectMaker("alibaba", "vercel", "alibaba/qwen3-coder");
    try expectMaker("moonshot", "fireworks", "accounts/fireworks/models/kimi-k3");
    try expectMaker("google", "cerebras", "gemma-4-27b");
}

test "maker: a lab's own provider, families, and unknowns" {
    try expectMaker("moonshot", "kimi", "k3");
    try expectMaker("openai", "codex", "gpt-5.6-terra");
    try expectMaker("minimax", "minimax", "MiniMax-M3");
    try expectMaker("openai", "openai", "o3-mini");
    try expectMaker(null, "lmstudio", "lmstudio-community/some-local");
    try expectMaker(null, "mlx", "mlx-community/whatever");
    try expectMaker(null, "fugu", "fugu-1");
    try expectMaker(null, "vercel", "someco/o30x"); // bare-digit family does not claim a longer word
}
