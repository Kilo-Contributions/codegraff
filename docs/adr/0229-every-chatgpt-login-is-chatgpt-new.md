# 0229. Every ChatGPT login is the `chatgpt-new` sign-in

Status: accepted 2026-10-01. Replaces the "Codex first" decision in ADR 0221.

## Context

ADR 0221 shipped the ChatGPT plan's sign-in for open-source apps as an opt-in
`chatgpt-new` provider and kept Codex the primary ChatGPT route until a change
on OpenAI's side forced the switch: `chatgpt` named the Codex login, and
`codex` preceded `chatgpt-new` in the provider table, so a bare model name and
the startup default resolved to Codex when both were signed in.

That change has come: the login through the Codex CLI's client no longer
works for graff. The sign-in for open-source apps is OpenAI's documented route
and the one that does.

OpenAI still refuses every refresh of the new sign-in with `invalid_grant`
([report](../upstream/openai-sign-in-refresh-invalid-grant.md)). The
documented refresh request is unchanged, and so are the other open-source
clients of the flow.

## Decision

- Every ChatGPT login name, `codex` included (`chatgpt`, `codex`, `openai`,
  `gpt`, `oai`), runs the `chatgpt-new` sign-in in `graff login`, `/login`
  and `graff logout` (`args.loginTarget`). Bare `/login` lists one ChatGPT
  entry.
- Picking a `codex` model with no credential offers the same sign-in and
  continues on `chatgpt-new`, on that model when the route serves it and on
  its default model otherwise.
- `chatgpt-new` precedes `codex` in the provider table and its Lean, Python
  and JSON mirrors, so a bare model name both serve and the startup default
  pick it when both have a credential.
- The `codex` provider stays for a `CODEX_HOME/auth.json` the Codex CLI
  wrote, and `graff login --refresh` still renews that file. A saved or
  explicit `provider/model` keeps its route, and graff never moves a session
  between the two routes on its own.

## Consequences

Until OpenAI's refresh works, a sign-in lasts an hour. A longer session stops
with a sign-in error, and `graff login chatgpt` signs in again; a returning
sign-in reuses the registration and skips consent. What only the Codex route
serves (hosted image generation and hosted tool search, ADR 0221) needs an
existing Codex CLI login. Revisit when OpenAI's refresh works.
