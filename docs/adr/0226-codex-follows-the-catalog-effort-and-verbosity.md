# 0226. Codex requests follow the model catalog's default effort and verbosity

Status: accepted 2026-10-01

## Context

The codex model catalog gives each model a default reasoning level and a
default text verbosity, and the route's own client sends both. graff sent
`medium` effort to every codex model the user had not set, and no
`text.verbosity`, so the server's `medium` applied. On a model whose catalog
default is `low` for both, each graff turn reasoned and wrote more than the
route's own client does.

A hill-climb round on wall time against a reference harness measured the
catalog defaults together with ADR 0227. Each change alone moved wall time
within noise. Together they cut it on the train and the held-out split, with
pass rate held.

## Decision

- `pricing.ModelInfo` has `default_verbosity`. The static codex rows carry
  the catalog's default effort and verbosity. `models_cache` reads both for
  the dynamic rows (`default_reasoning_level` or graff's `default_effort`,
  and `default_verbosity`) and writes them back. A value the wire does not
  accept is dropped, not guessed.
- `effort_route.wireEffort`: on the codex provider, `medium` (graff's
  default) is sent as the model's catalog default. Any other level is sent
  as chosen.
- The codex Responses body carries the catalog's `text.verbosity`.
  Compaction summaries and requests with a JSON output schema do not.

## Consequences

On a model whose catalog default is `low`, a turn reasons and writes less
and finishes sooner. `medium` is also the unset value, so an explicit
`/effort medium` on such a model sends the catalog default too; the same
function already maps `medium` this way for some other models. Choose
`high` for deeper reasoning. Revisit if a harder suite loses pass rate at
the catalog default, or when the catalog's defaults change: dynamic rows
follow it, the static rows are updated by hand.
