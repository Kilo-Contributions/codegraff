# 0250. PR publication is not gated

Status: accepted 2026-10-03. Supersedes 0120, 0123 (PR check observations),
0126 (publication retains observed check failures), 0133 (publication review
binds committed inputs), and the PR-readiness and verified-completion parts
of 0100 and 0104.

## Context

Since #847, a `gh pr create` without `--draft`, or a `gh pr ready`, issued
through bash went through a readiness preflight. Every local check graff had
seen in the session needed a successful run; the exact head commit's CI had
to pass, with up to a minute of waiting on a pending run; a model review
compared the PR body's claims with the committed source and tests; and
publishing armed a verification obligation that deferred `attempt_completion`
until a fresh look at the head's checks passed. A draft completed only as a
labeled, unverified handoff.

The gate added a prompt note to every request, a second model call per
publication, waits on remote CI, publication state that every session save
and resume carried, and several thousand lines of code and fixtures. Whether
a PR may merge with red or pending CI is the repository's decision, made by
its branch protection and review, not something the agent should hold back
on its own.

## Decision

- `gh pr create`, `gh pr ready` and related commands run like any other
  command: no local-check, head-CI or claim-review preflight, no pending-CI
  wait, and no completion obligation. A draft completes like any other task.
- The prompt drops the readiness rule and keeps only the claim-ownership
  sentence.
- Artifact claims are unchanged: a mutation of a branch, issue or PR that
  another live session has claimed is still refused before it runs (ADR
  0144), with the literal command parsing those claims rely on.
- Publication disclosure policy (what may be published at all, ADR 0066) is
  unchanged.

## Consequences

graff can open or un-draft a PR whose CI is red or still running, and a task
can complete without a CI result; the repository's own protections are what
remain. Sessions saved by earlier versions still load, and their recorded
publication state is ignored. The gate's integration scripts, tier-2 cases
and CI steps went with it, which lowers the tier-1 test-count floor.
