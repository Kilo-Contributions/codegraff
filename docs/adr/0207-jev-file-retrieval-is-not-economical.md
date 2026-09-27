# 0207. Jev file retrieval is not economical as a default

Status: rejected 2026-09-27

## Context

Jev is a decision model (TypeSafe System One) that returns a probability for
each yes/no question about a supplied state. It is billed at a published
$0.042 per million input tokens and nothing for output, and graff already
reaches it for `jev_effort`. jevgrep (`jg`) uses it to find the files that
answer a plain-language repository question: it walks the tree and asks Jev
about each directory, file and source chunk. The question was whether graff
should retrieve files the same way, either as a `locate` tool or as a ranking
stage after `codedb context`.

We measured retrieval only, with no coding model in the loop. The cases are
15 merged graff PRs that close an issue. The question is the issue title and
body; the answer is the non-test `src/*.zig` files the PR changed. Each case
ran on a checkout of the PR's base, so the fix itself could not leak into the
index. Three arms ranked files:

| Arm | Jev requests per question | Any answer file in top 5 | Answer files in top 5 | In top 8 |
|---|---|---|---|---|
| `codedb context` | 0 | 53% | 38% | 42% |
| `codedb` candidates (≤40) reranked by Jev | ~20–40 | 73% | 54% | 56% |
| Jev over every `src/` file | ~550 | 93% | 80% | 80% |

Each Jev request carried the issue text and the file's header comments and
declarations, about 900 input tokens. The full scan was the most accurate arm,
but it is one request per file: about 0.5M input tokens (≈ $0.02) and roughly
30 seconds with 16 concurrent requests for graff's ~550 source files. Cost and
latency grow linearly with the file count, so a 5,000-file repository would
need ≈ $0.20 and several minutes for each question. `jg` as shipped made about
1,000 requests per question here and printed 150–244 "relevant" files
(20–48k tokens of output), too much to hand a model unfiltered.

The rerank arm is cheap, but its gain is bounded by `codedb`'s candidate set:
in several cases no answer file was among the candidates, so reranking could
not recover it.

A cheap per-question retrieval call does not save money when the main model
runs on a flat-rate plan, which is how graff's coding models are commonly
used. There, Jev adds metered spend and up-front latency, and the benefit
would have to come from fewer model calls or less exploration, which this
measurement does not show.

## Decision

graff does not run Jev for file retrieval. There is no `locate` tool, no Jev
stage in `codedb context`, and no jevgrep integration, on by default or behind
a flag. `codedb` remains the retrieval path. `jev_effort` is unaffected.

## Consequences

Sessions pay nothing and wait for nothing beyond `codedb` to find files, and
no source content is sent to a third-party classifier for retrieval.

The measurement exposed weaknesses in `codedb context` for plain-language
questions, which are worth fixing there instead: a task over 1,024 bytes is
rejected outright, keyword selection on issue text often picks generic words,
and the semantic lane was unavailable in every run.

Revisit when any of these holds: a pruned traversal (directory decisions
first, skipping rejected branches) reaches full-scan recall within about 100
requests per question; Jev's price or latency drops by an order of magnitude;
or a whole-task comparison shows fewer model calls or a higher solve rate per
task with retrieval than without. A revisit must score whole tasks, including
failed ones, against a single fixed baseline per task.
