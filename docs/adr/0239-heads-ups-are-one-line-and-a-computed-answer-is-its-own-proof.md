# 0239. Heads-ups are one line, a computed answer is its own proof, and a new file needs no read

Status: accepted 2026-10-03

## Context

Paired runs against another coding harness, on the same models and plan and
the same tasks, showed that a model call's time follows the tokens it writes,
not the size of the context it reads. graff's calls wrote more than the other
harness's, and most of the difference was text the task did not ask for:

- **Narration.** The intro asked the model to "say what you found, then what
  you will do", and the heads-up note asked for one or two sentences before a
  large chunk of work. Models wrote a short paragraph ahead of most tool
  calls. The other harness asks for no narration and its models wrote almost
  none.
- **Second derivations.** "Make the requested thing work and prove it" read
  as license to compute an answer twice: a log census counted every file,
  then counted them again a different way in the same script and asserted
  the two agreed. Runs on the other harness never did this.
- **Reading files that do not exist yet.** `read_file` said "Call this before
  editing any text file", and models read paths they were about to create.

## Decision

- The intro asks for one short line, a dozen words at most, on what was found
  and what comes next. The heads-up note asks for a one-line heads-up in the
  same response as the tool calls it introduces (ADR 0061), one short line as
  each phase lands, and one line before a command that can run for minutes.
- The work note keeps "make the requested thing work and prove it" and adds
  that a script that computes an answer is its own proof: do not re-derive it
  a second way.
- `read_file` says to call it before editing an existing text file; a file
  about to be created needs no read.

On the paired runs, prose ahead of tool calls fell sharply, output tokens and
calls per task went down, and tasks finished sooner at the same pass rate.

Two alternatives were measured and not taken. Asking for no narration at all
was only slightly faster still, and it would leave the transcript with tool
rows and no narration (ADR 0021). Dropping the publishing, commit-authoring
and issue-filing segments saved nothing measurable, since prompt size does
not drive a call's time, and those segments carry safety rules.

## Consequences

The transcript shows one-liners where it showed short paragraphs. A plan that
needs explaining still goes in the final message. A computed answer is
trusted once its script runs. Revisit if a trace shows a wrong computed
answer that a second derivation would have caught, or if users find the
heads-ups too terse to follow a long task.
