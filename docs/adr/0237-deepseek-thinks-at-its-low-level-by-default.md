# 0237. DeepSeek thinks at its low level by default

Status: accepted 2026-10-02

## Context

ADR 0054 turned DeepSeek's thinking off when the wire effort is `low`, the
flash models' default. Every other effort sent thinking enabled with the
effort as chosen, so on DeepSeek V4 Pro graff's default (`medium`) thought at
length. DeepSeek documents `low`, `high` and `max`.

On tasks that read an MCP server, the first request of a turn reasoned for
thousands of characters and planned the whole job before its first tool call.
Another harness that sends DeepSeek's own default reasoned for a fraction of
that on the same tasks.

Sending `low` with thinking still enabled roughly halved graff's mean task
time on the core and MCP suites, and every task still passed. Turning thinking
off was faster again but lost a task there and missed a quarter of the
sub-agent runs.

On the sub-agent suites `low` was markedly faster too, most of all when
children did the work. Across two rounds it missed two runs that the default
passed: one child added up correct per-file counts wrongly, and one run
misread a route's method. The default missed as many in an earlier round.

## Decision

On the DeepSeek family (native `deepseek`, or a `deepseek*` model on another
provider), graff's default effort (`medium`) sends `reasoning_effort: low`
with `thinking.type=enabled`. `/effort low` still sends thinking disabled
(ADR 0054). `high` and above are sent as before, and the flash models' default
stays thinking off. The picker, status line and ACP still call the default
Medium.

## Consequences

A default DeepSeek turn reaches its first tool call sooner and spends less of
each request thinking. Work that needs care with exact figures, such as adding
up the counts a tool reported, gets less checking unless someone picks
`/effort high`.

Revisit if traces show default-effort DeepSeek runs failing where `high`
would have passed, or if DeepSeek documents a `medium` level.
