# 0251. Tool results inline up to 64 KiB

Status: accepted 2026-10-03. Raises the #440 handle threshold.

## Context

A tool result over the handle threshold reaches the model as a bounded
preview plus a handle (#440). The threshold was 16 KiB. graff's own modules
stop at 600 lines, which is 20-35 KB, so a whole-file read of an ordinary
module came back as a handle showing only its first half. On real-repository
fixes the model then paged the handle with `read_tool_result` or re-read line
ranges: three to five extra round trips per task, each costing seconds of
model latency.

Paired runs on real-repository fixes with the threshold at 64 KiB showed no
handle previews and no paging, fewer model calls and shorter tasks, and total
input tokens did not grow, because fewer calls re-send less context.

## Decision

- The default threshold is 64 KiB. `GRAFF_TOOL_HANDLE_BYTES` still overrides
  it.
- Small windows are unchanged in practice: `effectiveThreshold` already clamps
  the threshold to `Provider.perOutputCap()`, half the context window, so a
  32k-token model still gets about 16 KB inline.
- The codedb guard's small-read exemption follows the same number: a read that
  comes back whole is not a search and needs no codedb detour.

## Consequences

On large-window models one result can cost up to 64 KiB of context instead of
16 KiB; repeat sends of it are cache reads. Results larger than that still
become handles.
