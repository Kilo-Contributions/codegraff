# 0214. Evals are mined from history and hill-climbed on a held-out split

Status: accepted 2026-09-29

## Context

`graff-evals` already had the pieces of an eval loop: 59 task files, a live
suite of real merged PRs with a public named test and a hidden follow-up
test (gates G1–G6), and `hillclimb.py`, which ran a champion and candidates on
the same tasks and kept a candidate when most efficiency axes moved by more
than a fixed 2%. Three things were missing for decisions we can trust:

1. Every live task was written by hand, so the suite stayed at 12 tasks and
   drifted away from what graff is asked to do now.
2. Candidates were judged on the tasks their authors had looked at. Nothing
   could tell an improvement from tuning to those tasks.
3. The 2% threshold was a guess. Nobody had measured how far a score moves
   between identical runs, and graff passes 12/12 of the in-house suite, so
   pass rate there has no headroom left.

Local trajectories showed the other half of the problem. They pointed at real
failure modes: one model's `read_file` failing several times as often as
another's, turns ending with work still open, and repeated publication and
worktree refusals. They also showed that one headline number was wrong. The
trace's `cache_read_tokens / context_tokens` understated prompt-cache reuse on
chained Codex sessions, because `context_tokens` is the context meter, not the
server's input count. The trace now records the server's own split in a `usage`
line (see docs/architecture.md).

## Decision

Evaluation follows the method in "Automating eval design and hillclimbing":
production-aligned tasks, validated code graders, a fixed held-out split,
measured noise, and one change per round.

**Tasks are mined from merged PRs** (`graff-evals/design/mine_prs.py`). A PR
that adds named Zig tests and changes non-test code becomes a task. The merge's
first parent is the starting tree: recent parents build on the pinned
toolchain, so no reconstruction is needed. The PR's first new test is the public
check the prompt names, and a second new test is the hidden check appended
only at grading time (source `local-git` in `live_setup.py`). Release merges,
test-only PRs and PRs over 900 changed lines are skipped.

**A grader is validated before a person sees the task.** Grading
(`named_unit_check.py`) builds only the unit-test binary, filtered to the
named tests, runs it, and requires each name to have run and passed. A test
that never ran fails, and an unrelated flaky integration script cannot fail
it. On the parent tree plus both tests, neither may pass (a compile error or
an unreachable test counts). On the merge tree both must pass, and a second run
must give the same verdicts. That is three filtered builds per task, one
build at a time.

**A person approves each task.** `review` writes a local page, and `approve`
moves a validated candidate into the `mined` suite. The loop never picks its
own tasks from one model's failures.

**Trajectories choose what to look at, not what to tune to**
(`design/mine_trajectories.py`). The report covers tool errors by tool and
model, server-reported cache reuse, cache resets at turn starts split by
idle gap, stalls, retries, open work, and refusal texts. It is written under
`design/local/` and never belongs in an issue or PR.

**The loop holds out a test set and measures noise** (`hillclimb.py split`,
`noise`, `round`). The split is drawn once from a seeded hash of task ids and
is not redrawn between rounds. `noise` repeats the baseline and records, per
set and goal (pass, usd, wall, tokens), the spread of per-repetition scores.
The band is two standard errors of a difference between two means. It also
lists flaky train tasks and warns when the baseline is at 95% or more. A
`round` runs champion and candidate on both sets, and keeps the candidate only
when:

- the train score beats the noise band, and
- the test score improves.

Train up with test flat is reported as overfitting and reverted. Either set
regressing reverts. Chasing cost or latency may not lower the pass rate by
more than the band. After three rounds with no kept change the loop stops and
lists what still fails on train. Test-set details are never printed, only its
score.

**Model-guide advice enters as candidates, not edits.** The GPT-6 prompting
guide's recommendations (follow-through, skill precedence, test calibration,
plain prose) are harness variants that append the passage. They change graff's
prompt only if a round keeps them on gpt-6 models.

## Consequences

- The eval suite can grow from the project's own history at the pace PRs
  merge, with graders that are known to fail before the fix and pass after it.
- A candidate needs evidence on tasks it was not tuned against. Some changes
  that looked like wins on the old same-set comparison will now be reverted.
- Validation and rounds are expensive. Each mined task costs three filtered
  builds to validate, and each round runs two harnesses over both sets with
  repetitions. That is fine offline and never in CI.
- Mined tasks come from this repository's public history, so a model may
  have seen a fix during training. They compare harness configurations on the
  same model, and do not measure absolute capability.
- Mined tasks depend on the local git history and toolchain. A parent that no
  longer builds on the pinned Zig fails validation and is not offered. Older
  tasks still need the reconstructed-parent path.
- Revisit if the held-out set grows too small to move beyond noise, or if
  mined tasks turn out easier than the hand-picked live tasks. The fix then is
  more tasks, not a looser rule.
