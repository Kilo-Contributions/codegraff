# 0255. Codegraff Claude models use the native Messages endpoint

Status: accepted 2026-10-06

## Context

ADR 0003 sent every Claude alias on the codegraff provider through Chat
Completions, translated by the gateway. The translation loses the pieces the
Claude turn depends on: thinking blocks and their signatures on replay,
thinking block binding, images inside tool results, the 1-hour cache TTL, and
the model's full output budget.

## Decision

`usesMessages` (provider_codegraff.zig) routes Claude aliases on codegraff to
the gateway's native Messages endpoint, and the provider builds as the
Anthropic wire with bearer auth. `claude_wire.isClaudeApi` is the single
predicate for "this request speaks the real Claude Messages API" — the direct
Anthropic provider or a codegraff Claude alias — so request-body, header, and
cache code share one check. Other Anthropic-format providers keep their own
paths.

## Evidence

codegraff_messages_tests.zig pins the header set and byte-identical request
body against the direct provider's output.
