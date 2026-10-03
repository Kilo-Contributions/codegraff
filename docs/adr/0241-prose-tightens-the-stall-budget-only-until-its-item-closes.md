# 0241. Prose tightens the stall budget only until its item closes

Status: accepted 2026-10-03

## Context

#56 gave a stream a quarter of the stall budget once visible prose had
flowed, on the reasoning that bytes arriving and then stopping means a dead
socket. #401 made the WebSocket reader match the SSE reader. Both kept the
tightened budget for the rest of the response.

A response is a sequence of output items. A model that writes a one-line
heads-up and then composes several tool calls closes the message item and can
think in silence before the next item starts, and a large edit batch takes
longer than a quarter budget. Eval traces showed exactly that: a heads-up,
then a stall well inside the full budget, a reconnect, and the whole
generation paid again. The silence was the model thinking, which is what the
full budget exists for.

## Decision

On the Responses wire, prose tightens the between-lines budget only while the
item that holds it is open. An event that closes an output item
(`response.output_item.done`) restores the full budget; the next prose delta
tightens it again. The WebSocket reader tracks this in `TokenSignal.step` and
the SSE reader from its `partial_text` growth plus the same `closesItem`
check, so the two transports still mean the same thing. Other wires keep the
old rule: they have no item-close event the reader can rely on.

## Consequences

A stream that dies right after an item closes is caught by the full budget,
not the quarter, so that one case waits longer before the reconnect. A death
mid-sentence is still caught at the quarter. The #680 widening ladder is
unchanged. Revisit if traces show dead sockets lingering between items, or
another wire gains an item-close event worth reading.
