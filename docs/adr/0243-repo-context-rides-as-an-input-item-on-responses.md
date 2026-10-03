# 0243. Repo context rides as an input item on Responses wires that cache the instructions whole

Status: accepted 2026-10-03

## Context

ADR 0223 keys the ChatGPT-plan prompt cache by account so turn 1 in a new
repo reads the shared prefix another repo warmed. Request dumps against that
backend showed what is shared. It renders the tool definitions first and the
instructions after them, and caches the instructions as one unit: two repos
whose instructions differed only in the project layout reused the system and
tools prefix and nothing of the instructions. Changing one paragraph at the
start of the instructions gave the same cached length, so there is no
partial credit inside them.

The instructions carry two per-repo blocks: the project-instructions section
(AGENTS.md and friends) and the project layout. Static text follows them (the
skills list, the constraint block, the model guidance), so every first call
in a new repo paid for the whole instructions uncached.

## Decision

On the Responses wire for `codex`, `chatgpt-new` and `openai`, root turns
send the instructions without those two blocks and send the blocks, in prompt
order, as one developer message ahead of the conversation (the role ADR 0208
gives mid-session context). The message rides with the conversation's first
item: a chained delta already holds it server-side, and a prewarm sends no
input at all. The blocks are the ones the prefix holds now: the instructions
section hot_context tracks across compaction folds, and the layout snapshot
resume restores (ADR 0109). The system prompt itself is unchanged, so other
wires, other providers and subagents send exactly what they sent before.

## Consequences

Instructions are byte-identical across repos with the same capabilities, so
a new repo's first call reads them from the cache; only the repo's own block
is new. The model reads AGENTS.md and the layout from a developer message
instead of the instructions. Revisit if a model treats that message with less
weight than the instructions, or another backend shows the same
whole-instructions caching.
