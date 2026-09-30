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

The route is a preview with narrower limits than the metered API. OpenAI's
preview-limits and token-reference pages list them; each limit was probed
live on 2026-09-30, and all 45 checks behaved as documented:

- **Request shape.** HTTP requests set `store: false` and `stream: true`,
  send `input` as an array, and carry instructions in `instructions` or
  developer messages; a system-role item is rejected. The route rejects
  `background`, `conversation`, `max_output_tokens`, `max_tool_calls`,
  `metadata`, `moderation`, `multi_agent`, `prompt`,
  `prompt_cache_retention`, `safety_identifier`, `temperature`,
  `top_logprobs`, `top_p`, `truncation` and `user`, and, found by probing,
  `prompt_cache_options` and `prompt_cache_breakpoint`. `prompt_cache_key`
  is accepted.
- **Conversation state.** HTTP rejects `previous_response_id`. The Responses
  WebSocket (`wss://api.openai.com/v1/responses`, bearer only) serves every
  listed model, and there `previous_response_id` chains with `store: false`,
  but only to a response made on the same connection: a second socket gets
  ``Invalid `previous_response_id` ``. A `generate: false` prewarm returns a
  chainable id, and GPT-6 models accept `response.steer` with string or item
  input, end the original `incomplete` with reason `steered`, and stream a
  successor.
- **Tools.** OpenAI asks for function and custom tools grouped in namespaces
  or supplied as `additional_tools` input items (role `developer`); both
  work, and flat function and custom tools are accepted too. `web_search`
  works, subject to model and workspace policy. Image generation and tool
  search are refused with `subscription_sharing_unsupported_capability`;
  file search, Code Interpreter, computer use, hosted MCP and
  `programmatic_tool_calling` are unsupported tool types.
- **Inputs.** Text, images and files work (an inline PDF was read). Audio
  input, the Files API and transcription do not.
- **Other endpoints.** `/responses/compact`, `/responses/input_tokens`, chat
  completions, embeddings and images are not authorized. `GET /v1/models`
  works but hides newer models unless `client_version` is sent.
- **Behavior.** Structured outputs, reasoning summaries and in-stream
  `context_management` compaction work over HTTP and the socket. The
  threshold counts input items, not instructions or tools, and a later turn
  answered from the compaction blob alone. Prompt-cache reads are
  intermittent (a repeated prefix sometimes reads back a few thousand
  tokens); writes are never reported. `service_tier: "priority"` is accepted
  and ignored.
- **Errors.** Plan limits arrive as `subscription_sharing_usage_limit_exceeded`
  or `subscription_sharing_usage_unavailable`, on a 429 or mid-stream as
  `response.failed`. An expired access token is a 401 with
  `{"detail":{"error_code":"invalid_token"}}`. A rejected field is a 400
  whose `detail` names it.
- **Tokens.** The access token is a one-hour RS256 JWT (`aud`
  `https://api.openai.com/v1`, `iss` `https://auth.openai.com`, the issued
  `client_id`, the granted scopes, and opaque OpenAI metadata graff never
  reads). A refresh returns a new access token and a replacement refresh
  token; refresh tokens last 30 days, renewed by every refresh.
  `earliest_refresh_at` falls six minutes before expiry, and a refresh
  before it answers `invalid_grant` and spends the refresh token.

OpenAI also documents running Codex app-server on the same token (stdio to
app-server, then HTTP/SSE, with `supports_websockets=false`). Graff calls
the Responses API itself, so it keeps the WebSocket and renews the token in
process rather than restarting anything.

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
  issued client id five minutes before expiry (inside the six-minute window)
  or after a 401, under the existing refresh mutex, and never before
  `earliest_refresh_at`: OpenAI answers an early refresh with
  `invalid_grant`, which spends the refresh token. A lock file beside the
  record serializes refreshes across graff processes, as OpenAI asks: the
  loser of a race would present a replaced token (`refresh_token_reused`) and
  force a new sign-in, so it re-reads the record under the lock and adopts
  the winner's token. An unusable refresh token is cleared; a network
  failure keeps everything.
  `graff logout chatgpt-new` revokes the refresh token and keeps the client id and
  host id.
- **Request shape**: no prompt-cache options or anchor (those stay keyed to
  `openai`), `reasoning.summary: "auto"`, in-stream compaction
  (`manualRoute` returns `.in_stream`), no hosted tool search, async
  `webfetch` on GPT-6 models, and RLM `llm_query` sends a streamed body and
  reads its SSE text. The tool catalog goes flat, as it does to the metered
  API; if the route starts enforcing namespaces, the fix is to wrap it in
  one.
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
`earliest_refresh_at` spends the refresh token, so that gate must hold. A
sign-in lives as long as graff refreshes it within 30 days; after a longer
gap the error says to run `graff login chatgpt-new` again.
