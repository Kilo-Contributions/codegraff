# Terminal-Bench (Harbor) adapter

Runs graff as a [Harbor](https://www.harborframework.com/docs/agents) installed
agent, so it can be scored on Terminal-Bench and other Harbor datasets beside
other agents. Each trial installs the static Linux graff binary in the task
container and solves the task as one headless `graff -p` run with every tool
approved. Headless runs wait for their own background work before they end
(ADR 0215), so a build or test suite started in the background is collected.

Needs Python 3.12+, [uv](https://docs.astral.sh/uv/), and a Harbor environment:
Docker, or `apple-container` on Apple silicon (Apple's `container` CLI).

```sh
uv sync --project graff-evals/harbor
```

## Run

The model is `provider/model` as graff names it. Harbor passes the provider's
key through to graff (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`OPENROUTER_API_KEY`, `XAI_API_KEY`, `DEEPSEEK_API_KEY`, ...). graff has no
generic base-URL override, so a custom endpoint needs a graff provider for it.

```sh
export ANTHROPIC_API_KEY=...
uv run --project graff-evals/harbor harbor run \
  -d terminal-bench/terminal-bench-2-1 \
  -a graff_harbor.agent:Graff \
  -m anthropic/claude-sonnet-5-5 \
  --ak version=v0.0.302.10 \
  -e docker -n 4 --job-name tb-graff
```

Agent options (`--ak`):

| option | meaning |
| --- | --- |
| `version` | Release to install, such as `v0.0.302.10`. Omit for the latest release. The tarball is checked against the release's `SHA256SUMS`. |
| `binary` | A local static Linux graff binary to upload instead, for an unreleased build: `zig build graff -Doptimize=ReleaseFast -Dtarget=x86_64-linux` (or `aarch64-linux`). |
| `max_model_calls` | Stop the run after this many model calls (`--max-model-calls`). |

Each trial's `agent/` directory holds `graff.stdout` (the answer),
`graff.stderr` (progress and the usage footer that fills Harbor's token
counts), and `graff-state/` (the run's `.graff/`: session and traces). The
`.graff/` directory is moved out of the task tree so the verifier sees only
the agent's changes. Inspect a job with `harbor view jobs/<job-name>`.

## Tests

```sh
uv run --project graff-evals/harbor python -m unittest discover -s graff-evals/harbor/tests
uv run --project graff-evals/harbor python graff-evals/harbor/tests/smoke.py --environment docker
```

The smoke test runs one real Harbor trial against graff's scripted test model
inside the task container (graff's `lmstudio` port), so it needs no API key.
Under `apple-container`, containers on some hosts cannot resolve names; pass
`--binary` with the matching Linux build so nothing is downloaded inside the
container:

```sh
uv run --project graff-evals/harbor python graff-evals/harbor/tests/smoke.py \
  --environment apple-container --binary /path/to/graff-aarch64-linux/graff
```
