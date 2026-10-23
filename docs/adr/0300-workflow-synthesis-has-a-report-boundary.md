# 0300. Workflow synthesis has a report boundary

## Context

A synthesis worker receives earlier findings but previously had the same
unbounded tool loop as an investigator. Changing each read slightly avoids the
identical-call guard, so a final summary could become another investigation
without ever returning a report. A failed final phase also returned its own
failure while losing the previous phase's evidence from the workflow result.

## Decision

Canonical `synthesize` phases and pipeline stages have a worker-local allowance
of eight evidence-bearing model requests, followed by one report-only request.
The final request omits tools and explicitly asks for a qualified summary.
Dispatch also refuses tools at that boundary even if a model emits one anyway.
The allowance stays on the worker across turn retries; it is not a renewed
per-request or per-turn counter. Ordinary workers and root turns are unchanged.

A worker that still does not finish fails with `WorkflowSynthesisLimit`, not a
successful-looking timeout report. That failure is not retried as a fresh
worker. Cancellation is likewise classified as cancellation, not an unknown
transient failure. Workflow and pipeline failure results retain bounded prior
stage evidence, explicitly labeled incomplete and not newly verified.

This is shared engine policy, so it applies on the line REPL and ACP clients.
The bound is on evidence requests, not an elapsed-time guarantee: transport and
individual tool deadlines continue to own their existing limits.

## Consequences

Synthesis can retrieve details missing from bounded phase summaries, but cannot
silently redo an entire review. A task requiring further investigation belongs
in a finder or verifier stage; a synthesis answer may instead identify a gap.
No whole-session cap is introduced, and useful earlier findings survive even
when the final report cannot be produced. Offline ACP and JSON fixtures cover
unique (not merely identical) repeated calls, tool refusal, retained evidence,
non-retryable exhaustion, and unchanged ordinary workers.
