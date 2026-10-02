# What the harness comparisons mean for an engineering budget

A rough guide built from two measured comparisons, each on the same model
and account in both harnesses:

- [graff vs the Codex app server](graff-vs-codex-app-server/RESULTS.md) (`gpt-6.1-sol`)
- [graff vs the Grok CLI](graff-vs-grok-cli/RESULTS.md) (`grok-4.7`)

Both ran the same 21 coding and MCP tasks, 3 times each. Costs are list
prices of the tokens each harness used.

## Per task

| Compared with | graff | Other harness | graff costs |
| --- | ---: | ---: | ---: |
| Codex app server, its reported usage | $0.0164 | $0.0278 | 41% less |
| Codex app server, with its unreported warm-up request | $0.0164 | up to $0.0524 | up to 69% less |
| Grok CLI, grok-4.7 public list price | $0.039 | $0.26 to $0.33 | 85% to 88% less |
| Grok CLI, xAI's price for its build-model route | $0.039 | $0.098 | 60% less |

## At company scale

An illustrative organization: 100 engineers, each running 40 agent tasks per
working day, 21 working days a month, so 84,000 tasks a month at the per-task
costs above.

| Compared with | graff per month | Other per month | Saved per month | Saved per year |
| --- | ---: | ---: | ---: | ---: |
| Codex app server, reported usage | $1,378 | $2,335 | $958 | $11,491 |
| Codex app server, with warm-up | $1,378 | $4,402 | $3,024 | $36,288 |
| Grok CLI, public list price | $3,284 | $22,042 to $27,770 | $18,757 to $24,486 | $225,086 to $293,832 |
| Grok CLI, xAI's build-model price | $3,284 | $8,240 | $4,956 | $59,472 |

Time moves too. Against the Grok CLI, graff took 15.5s per task against
106.9s: about 2,100 fewer hours of agent wall time a month at this volume.
Against the Codex app server graff was slower, 28.2s against 25.0s per task
(about 75 more hours a month).

## How far this carries

- **Real tasks are bigger.** These tasks average about 30k prompt tokens in
  graff. Cost grows with tokens, so the percentage is the part that
  transfers: an organization spending $X a month on agent runs in one of
  these harnesses would spend roughly the "graff costs" share of $X for the
  same work.
- **MCP-heavy work saves the most.** Most of the gap against the Grok CLI is
  on MCP tasks, where it re-sends every tool result on every turn.
- **Plans are not per-token bills.** Both comparisons ran on subscription
  sign-ins; the dollars are list-price equivalents, which is what API-key
  usage pays.
- **Small samples.** 3 runs per task on one machine and one account per
  comparison. Run [`graff-evals`](../graff-evals) on your own tasks before
  budgeting from these numbers.

## Enterprise

graff is licensed under a modified AGPL-3.0 ([LICENSE](../LICENSE)). From
the release after v0.0.302.15, a company that has raised more than US$500k
(at any valuation, counting its affiliates) needs a commercial license for any
use, including on its own machines, CI and network. Contact
[rach@standardharness.com](mailto:rach@standardharness.com) for a license,
support, and deployment help.
