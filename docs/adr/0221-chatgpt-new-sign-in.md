# 0221. The ChatGPT plan's new sign-in is an opt-in `chatgpt-new` provider; Codex stays the primary route

Status: accepted 2026-09-30

## Context

OpenAI documents a sign-in for open-source apps that run on the user's own
machine ([Sign in with ChatGPT for open-source apps](https://developers.openai.com/siwc/token-sharing-open-source)).
The user registers the app in their ChatGPT account, and its OAuth access token
pays for Responses API requests from their ChatGPT plan. The `codex` provider
signs in through the Codex CLI's client and calls the ChatGPT backend; this flow
gives Graff its own registration and uses the public
`https://api.openai.com/v1/responses`.

The route accepts less than the metered API. Probed with a plan token:

- HTTP requests must set `store: false` and `stream: true`.
  `previous_response_id`, `max_output_tokens`, `truncation`, `metadata`,
  system-role messages, `prompt_cache_options` and `prompt_cache_breakpoint`
  are rejected.
- The Responses WebSocket (`wss://api.openai.com/v1/responses`, bearer only)
  serves every listed model. On the socket `previous_response_id` chains with
  `store: false`, so a follow-up carries only its new items; a
  `generate: false` prewarm returns a chainable id; GPT-6 models accept
  `response.steer` with string or item input, end the original `incomplete`
  with reason `steered`, and stream a successor.
- `/responses/compact`, `/responses/input_tokens`, chat completions,
  embeddings, images, audio and files are not authorized. `GET /v1/models`
  works but hides newer models unless `client_version` is sent.
- Function, custom, namespaced and async tools, hosted `web_search`,
  structured outputs, reasoning summaries and in-stream `context_management`
  compaction work, and compaction items replay: a later turn answered from
  the blob alone. Other hosted tools are rejected. `service_tier: "priority"`
  is accepted and ignored.
- Prompt-cache reads are intermittent (a repeated prefix sometimes reads back
  a few thousand tokens); writes are never reported.
- Plan limits arrive as `subscription_sharing_usage_limit_exceeded` or
  `subscription_sharing_usage_unavailable`, on a 429 or mid-stream as
  `response.failed`. An expired access token is a 401 with
  `{"detail":{"error_code":"invalid_token"}}`.

## Decision

- **Codex first.** Codex stays the primary ChatGPT route: `chatgpt` still
  names its login (`/login chatgpt`, `graff login`), `codex` precedes
  `chatgpt-new` in the provider table so a bare model name and the startup
  default resolve to Codex when both are signed in, and graff never moves a
  session between the two routes on its own.
  The new route waits, fully working, for the change on OpenAI's side that
  forces the new method; switching then means pointing the `chatgpt` login
  alias and the ChatGPT defaults at `chatgpt-new`.
- **A separate `chatgpt-new` provider** (`ProviderSpec.login =
  .chatgpt_browser`, `sub_login`), not a login on `openai` or `codex`: its model
  rows carry 272k windows (`contextFor` clamps it like codex), it bills
  flat-rate, and its request shape differs from the metered API's.
- **`graff login chatgpt-new`** (or `chat-gpt-new`). The first sign-in registers with
  `client_id=dynamic_agent_client` and `agent_name_hint=Graff`; later sign-ins
  reuse the issued client id with `id_token_hint` and `login_hint`. PKCE S256,
  an OIDC nonce, `resource=https://api.openai.com/v1`, a loopback callback on
  `127.0.0.1` (port 1455, then 1456–1459), and one `ext_agent_host_id`
  (`urn:uuid:`, version 4) per machine.
- **Nothing is saved before the ID token verifies**: RS256 against the
  published JWKS, then issuer, audience (the issued client id), expiry and
  nonce. Plan usage needs the `chatgpt.tokens.use.direct` scope; a sign-in
  without it is saved but never used for requests.
- **One record per machine** in `<home>/.openai/credentials/graff-oauth.json`
  (0600, atomic), with the host id beside it. Refresh sends `resource` and the
  issued client id, near expiry or after a 401, under the existing refresh
  mutex, and never before `earliest_refresh_at`: OpenAI answers an early
  refresh with `invalid_grant`, which would otherwise read as a dead token.
  `graff logout chatgpt-new` revokes the refresh token and keeps the client id and
  host id.
- **Request shape**: no prompt-cache options or anchor (those stay keyed to
  `openai`), `reasoning.summary: "auto"`, in-stream compaction
  (`manualRoute` returns `.in_stream`), no hosted tool search, async
  `webfetch` on GPT-6 models, and RLM `llm_query` sends a streamed body and
  reads its SSE text.
- **Transport**: live turns use the Responses WebSocket like codex, chaining
  `previous_response_id` on the held socket, steering GPT-6 turns, and
  prewarming when `GRAFF_WS_PREWARM` is set. One-shot and quiet turns stay on
  HTTP, which never sends `previous_response_id`; a socket failure falls back
  to it. A chat turn closes the socket it opened.
- **Errors**: plan-usage codes fail fast, on a 429 or mid-stream, with a link
  to ChatGPT's usage settings. They are never retried as a flake and never
  fall back to another credential. `invalid_token` is an auth error: one
  refresh and retry, then the error says to sign in again.
- **Compaction**: the in-stream blob carries the prompts it pruned, so a
  history holding a blob counts as conversation state and is saved.
- **The callback page** follows codegraff.com's design, embeds its images so it
  makes no network request while the code is in the address bar, clears the
  code from the URL, and answers after the exchange so it shows the real
  outcome.
- `GRAFF_BROWSER` chooses the browser every graff sign-in opens.

## Cost

Tokens are per machine: another machine signs in again and reuses the
registration. Two ChatGPT routes coexist until the switch, so the picker
lists both. Hosted use (the gateway, hosted sandboxes) is out of scope;
OpenAI requires a separate agreement for it. The live account catalog is a
follow-up, so the offline model rows can lag a rollout. HTTP requests re-send
the whole input and caching is intermittent, so one-shot runs pay the most;
live turns chain on the socket instead. A refresh before
`earliest_refresh_at` spends the refresh token, so that gate must hold.
