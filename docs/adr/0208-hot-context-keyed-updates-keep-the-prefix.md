# 0208. Hot context: keyed updates ride the tail, compaction folds them in

Status: accepted 2026-09-27

## Context

The root system prompt is composed once at startup, and the provider caches
it as a prefix (ADR 0011). Two things in it can go stale during a live
session: the project instructions file (`AGENTS.md` / `HARNESS.md` /
`CLAUDE.md`) and the calendar date. Rewriting the system prompt when either
changes discards the cached prefix on every edit. Leaving them frozen means
the model keeps following rules the user has already changed (#1333).

A first cut sent updates as user-role messages. On the Responses wire, the
model kept following the old system-prompt rule, because a user message
ranks below system/developer instructions in that wire's instruction
hierarchy.

## Decision

- Ambient values are keyed sources in `src/hot_context.zig`:
  `core/instructions` and `core/date`. Before each root model request,
  `turn_inbox.deliver` diffs them against what the model last saw (a stat
  probe first, then a content hash) and sends only the changed keys.
- Each changed key becomes one `<context key="...">` message, inserted just
  before the pending user prompt. It is tagged `_graff_origin:
  "hot_context"`, so it is treated as a notice and never as a human turn.
  Everything already sent keeps its bytes, so the prefix still reads from
  the cache.
- The role depends on the wire, so that the update outranks the stale
  prompt:

  | Wire | Role |
  |------|------|
  | Responses | `developer` |
  | Chat Completions | `system` |
  | Anthropic Messages | `user` (no mid-thread system role) |
  | Interactions | `user` (no mid-thread system role) |

  A `/model` switch across wires retypes the update instead of dropping it
  (`history_translate.zig`).
- Compaction already loses the cached prefix. After a client summary, an
  emergency trim, or a provider-side compaction, `afterCompact` does two
  things. It removes the update messages. Then, if the file differs from
  what the prompt holds (or the date has moved), it folds the latest section
  and date into the system base through `prompts.setSystemPrompts`.
  `afterCompact` compares hashes instead of looking for surviving update
  messages, because the summary's working set usually drops them already.
- `/cache` shows `hot ctx  N updates  last: <key>  (appended; prefix kept)`.
  An update is not counted as a bust.
- Only the root session gets updates. Subagents get their brief when they
  are spawned.

## Consequences

An instruction edit now costs one small message at the end of the history
per change, not a full prefix miss. The file is read from the process cwd.
An ACP session that enters another tree (or runs `workspace use`)
therefore receives that tree's instructions as an update.

Revisit this if a Chat Completions provider rejects a mid-thread `system`
message. The fallback is to send `user` for that provider id only, not for
the whole wire.
