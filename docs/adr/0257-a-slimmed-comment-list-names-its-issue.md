# 0257. A slimmed comment list names its issue

Status: accepted 2026-10-06

## Context

Large MCP list results are slimmed before the model sees them (ADR 0029,
ADR 0225): a comment list becomes `{"n": count, "latest_author": name}` and
the full result goes to a handle. The fold dropped every field of the rows,
including the issue they belong to.

When a model fetched several issues' comments in one response, each result
came back paired with its call, but nothing in the result itself said which
issue it described. Handles are numbered as results complete, so in a batch
they do not follow the order of the calls. Sub-agents on the eval tasks that
fan out over issues reported the right counts against the wrong issues: the
counts followed the handle numbers, not the calls.

## Decision

When every comment row carries the same parent id (`issueId`, `issue_id`, or
a nested `issue.identifier` / `issue.id`), the fold keeps it first:
`{"issue": "ISS-4", "n": 4, "latest_author": "jay"}`. Rows that disagree, or
any row without the field, fold as before. The load note that states the slim
rule says so.

## Consequences

A result names its own issue, so pairing no longer depends on call order or
handle numbers. The fold grows by one short field when the rows carry it.
Handles stay numbered by completion; nothing should read order into them.
