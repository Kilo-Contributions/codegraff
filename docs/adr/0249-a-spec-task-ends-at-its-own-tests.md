# 0249. A spec task ends at its own tests

Status: accepted 2026-10-03

## Context

ADR 0024 added a sentence to the work note: a named SPEC.md is the whole
contract, and a green public test is not the whole spec. It was written for
one spec miss, a streaming-JSON task whose whitespace-only input counts as
empty.

Paired runs on the spec-driven SWE tasks showed the sentence no longer does
that job — with it, without it, and in a comparison harness that never had
it, that edge is still missed — but it changes the shape of every spec task.
Once the task's own tests pass, the model writes a second, ad-hoc
verification script against the spec's clauses: one long extra call per
task that found nothing the hidden checks wanted. The comparison harness,
which stops at the task's tests, passed the same tasks. A rewording that
kept the sentence but asked for a reading check instead of a script
recovered only part of the cost.

## Decision

Remove the sentence from the work note. The rest of the note already says
to make the requested thing work, prove it, and add no unrequested tests,
so the task's own tests are the proof. The lean work note keeps its copy;
it was not measured.

## Consequences

Spec tasks end once their tests pass: fewer output tokens and shorter turns,
with the same pass rate in paired runs. If a model starts missing spec
clauses no public test covers, the answer belongs in that task's tests, not
in a standing instruction every spec task pays for.
