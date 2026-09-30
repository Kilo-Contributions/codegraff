# 0223. The codex cache partition is the account, not the repo

Status: accepted 2026-09-30

## Context

ADR 0028 made the codex `session_id` header the Responses
`prompt_cache_key`, and ADR 0069 seeded that key on the git root (or one
shared scratch seed). The system prompt and the tool catalog carry no cwd:
a session in any repository sends the same prefix bytes. Every repository
still got its own key, so turn 1 in a repository the account had not used
recently read that prefix cold, even when another repository had just warmed
it. Eval sandboxes are each their own git repository, which made the cold
first read the largest single cost gap against a reference harness that
warms its own prefix with an extra request per thread.

A hill-climb round against that harness, with the order of the arms then
reversed, measured one key per account: turn-1 cache reads rose, cost per
task fell on the train and the held-out split, and pass rate held.

## Decision

- For the codex provider with a ChatGPT account id, the root partition base
  is a name-derived UUID of the account (`cache_affinity.accountRootId`).
  Root labels (`main`, `/btw`) use it; children keep their four role lanes on
  it (`<base>-child-N`, ADR 0069's fan-out rule).
- `http_headers.requestCacheKey` takes the Provider. Every request path uses
  it (HTTP, HTTP/2, the WebSocket handshake, the Responses body, the
  non-streaming post, and server compaction), so header and body stay equal.
- Other providers, and codex without an account id, keep the project key.

## Consequences

One account's sessions share one routing key on this backend. Parallel
sessions concentrate on it; subagent fan-out still spreads over the child
lanes. Revisit if traces show conversation-tail cache reads dropping under
concurrency.

The persisted session `prompt_cache_key` stays the project id. Resume does
not need it for codex: the account key is derived per request.

Offline guards: `cache_key_tests.zig` (account partition, `/btw` and role
lanes on it, another account is another partition, other providers and a
missing account keep the project key, `session_id` header agreement) and the
catalog-wide `spec_prompt_cache_conformance.zig`.
