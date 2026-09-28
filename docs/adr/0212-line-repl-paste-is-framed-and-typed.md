# 0212. Line-REPL pastes remain framed and typed through active turns

Status: accepted 2026-09-28

## Context

The idle line editor enabled bracketed paste but disabled it on submit. A multiline paste during model or tool work then reached the mid-turn stdin watcher as individual keystrokes: pasted newlines queued separate steering prompts, and an empty pasted line could force an interruption. The watcher and turn-boundary queue drain also shared mutable draft state. A dropped `data:image` URI could instead fall through as prompt text. See [#1367](https://github.com/justrach/codegraff/issues/1367).

## Decision

Keep bracketed-paste mode enabled from the first interactive line edit until terminal release; restore the editor's modified-key mode after each line. The mid-turn scanner tracks paste markers across reads and treats their contents as one draft. Only an Enter *after* the closing marker queues it; a later empty Enter still explicitly forces the queued turn. Serialize scanner input, draft/queue mutation, and turn-boundary reset.

Before expanding an idle paste as text, classify recognized image data URIs. Validate their encoding and image type, bound their size, then stage a native image attachment or reject them locally. Never submit a rejected URI as prompt text. Structured context-overflow errors do not become transient gateway retries merely because their message says to try again.

## Consequences

Terminals supporting bracketed paste preserve multiline steering atomically; terminals without it still cannot distinguish a paste from repeated Enter keystrokes. Every graceful line-REPL exit must disable the terminal mode. Image drops now use bounded decoding memory and fail visibly when unsupported; ordinary text pastes and genuine transient gateway retries keep their existing behavior.
