# 0261. The client summary stays the compactor; Clef pruning is opt-in

Status: accepted 2026-10-07. Supersedes 0260's default.

## Context

0260 added a gateway path (`POST /v1/compact`, Clef keep/drop decisions over
tool calls) ahead of the client summary in `compact()`, and the code shipped
it default-on while the ADR said default-off. `evals/clef_exp` then measured
five arms — Clef prune, client summary, two-pass mix, Clef-then-mix, and no
compaction — across three hosted chat-wire models, plus an archive mode
(`GRAFF_CLEF_ARCHIVE`) that stubs pruned outputs to session artifacts
instead of deleting them, and a recall variant where facts exist only in
deleted-after-read tool output.

What it showed:

- The client summary works. Each install shrank history by about a third;
  an earlier reading that it "pin-degrades and never installs" misread
  `compact_cut`'s `unresolved` trace field.
- Clef rarely prunes. Most Clef-arm compactions were `clef_compact_noop`
  followed by the summary fallback, so the arm paid for decision calls and
  then ran the summary anyway. On the recall variant it pruned nothing, and
  archive mode never engaged.
- Answer quality did not separate the compacting arms in Clef's favor. On
  the recall variant the summary arm scored highest of the compacting arms.
- Graff already keeps a recoverable copy of every tool output: the session
  transcript (#441). Models recovered "lost" facts by grepping it on every
  arm, so archive mode adds a path, not data.
- Not compacting stays cheapest; every rewrite busts the prompt cache.

## Decision

- `GRAFF_CLEF_COMPACT` defaults OFF (`agent_clef_compact.g_enabled = false`).
  `compact()` uses the client summary; `GRAFF_CLEF_COMPACT=1` arms the
  gateway path for experiments, with the same fall-through-to-summary on any
  failure or noop. `GRAFF_CLEF_ARCHIVE=1` stays an experiment-only modifier.
- The pre-compaction note-to-self (#391) is unchanged and stays visible: it
  carries working state a summary drops across long sessions.
- First-party Responses routes (direct API, gateway GPT models, the
  ChatGPT-plan sign-in) compact only through the provider's own compaction
  and never reach `compact()` — neither the summary nor Clef (ADR 0259). Any refactor
  of `compactOrRecover` (e.g. the `agent_compact_recover.zig` split) must
  keep the `serverOnly(provider)` branch that enforces this.

## Consequences

No gateway decision call, and no transcript sent to the gateway, on default
compactions — which also retires 0260's missing disclosure notice. The Clef
code stays for measurement. Revisit if a task shape shows the summary losing
information that Clef keeps: the recall variant should block the session
transcript first, since today it lets every arm recover pruned output.
