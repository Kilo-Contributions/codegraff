# 0120. Draft publication does not complete verification

Status: accepted 2026-09-15; draft authorization removed 2026-09-27

## Context

A draft PR could bypass the persisted verification obligation even when its
checks failed. Replacing the checklist with a completed handoff item and
calling `attempt_completion` then recorded completion of a verified-PR task.
The unverified label did not protect the acceptance contract (#931).

## Decision

A publication still arms an obligation independently of checklist wording.
Every completion attempt reads fresh head evidence. A draft is insufficient
by default, even if its checks pass; failing base-branch checks explain a
blocker but do not waive the task's requirements.

A draft PR at completion ends the run as an unverified handoff. No user
command is needed; the `/pr-acceptance` control and the JSON `prAcceptance`
option were removed on 2026-09-27. Stopping a run to ask the user to type a
command only to hand back a draft cost more than it protected. The result
text starts with "Draft handoff — CI is not verified.", and the draft never
counts as verified task success (`taskVerified` stays false). A stale local
head still defers completion. Ready PRs still require passing current-head
checks. This keeps ADR 0104's distinction between a draft handoff and
verified task completion.

## Verification

Offline production-dispatch cases publish through a local GitHub CLI fixture,
replace todos, and repeat completion attempts. They cover failing head/base
checks, draft handoff completion, and successful verified completion.
The failure cases reproduce on the preceding release build.
