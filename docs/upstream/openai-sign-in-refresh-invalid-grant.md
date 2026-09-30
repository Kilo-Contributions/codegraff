# Sign in with ChatGPT for open-source apps: every token refresh returns `invalid_grant`

- **Service:** Sign in with ChatGPT for open-source apps (token-sharing
  preview), `https://auth.openai.com/api/accounts/oauth/token`
- **Client:** graff, an open-source coding agent
  (https://github.com/justrach/codegraff), provider `chatgpt-new`
  ([ADR 0221](../adr/0221-chatgpt-new-sign-in.md))
- **Observed:** 2026-09-29 and 2026-09-30

## Summary

Registration, sign-in, the authorization-code exchange and Responses
requests all work. Refreshing does not: every `grant_type=refresh_token`
request so far has returned HTTP 400 `{"error": "invalid_grant"}` with no
`error_description`. That includes two requests sent inside the renewal
window with refresh tokens that had never been used, one of them 60 seconds
before the access token expired. So a sign-in lasts one hour, and a task
still running when the access token expires fails with `invalid_token`.

## Request

The request in "Refreshing tokens", field for field:

```http
POST /api/accounts/oauth/token HTTP/1.1
Host: auth.openai.com
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token&client_id=<issued oaiapp_ client id>&refresh_token=<latest refresh token>&resource=https%3A%2F%2Fapi.openai.com%2Fv1
```

`client_id` is the issued client id saved with the token set, not
`dynamic_agent_client`. There is no `scope`. To reproduce with the values
from a token response:

```sh
curl -sS https://auth.openai.com/api/accounts/oauth/token \
  --data-urlencode grant_type=refresh_token \
  --data-urlencode client_id="$ISSUED_CLIENT_ID" \
  --data-urlencode refresh_token="$REFRESH_TOKEN" \
  --data-urlencode resource=https://api.openai.com/v1
```

## Expected

HTTP 200 with a new access token and a replacement refresh token, as the
token reference describes.

## Actual

```http
HTTP/1.1 400 Bad Request

{"error": "invalid_grant"}
```

## Attempts

| # | Sent | Request | Refresh token | Result |
|---|---|---|---|---|
| 1 | About 50 minutes before `earliest_refresh_at` | Documented | Unused | 400 `invalid_grant` (expected, too early) |
| 2 | About 8 minutes after `earliest_refresh_at`, just after the access token expired | Documented | The token from attempt 1 | 400 `invalid_grant` |
| 3 | 63 seconds after `earliest_refresh_at`, 5 minutes before the access token expired | Documented | Unused, from a sign-in 55 minutes earlier | 400 `invalid_grant` |
| 4 | 60 seconds before the access token expired, 5 minutes after `earliest_refresh_at` | Documented | Unused, from a sign-in 59 minutes earlier | 400 `invalid_grant` |
| 5 | Within a second of attempt 4 | Documented, plus `ext_agent_host_id` | The token from attempt 4 | 400 `invalid_grant` |
| 6 | Within a second of attempt 4 | Documented, without `resource` | The token from attempt 4 | 400 `invalid_grant` |
| 7 | Within a second of attempt 4 | Documented, plus `scope` set to the granted scopes | The token from attempt 4 | 400 `invalid_grant` |
| 8 | 30 seconds after the access token expired | Documented | The token from attempt 4 | 400 `invalid_grant` |

Attempts 3 and 4 rule out timing and reuse: each token had never been sent,
and each request fell inside the renewal window. Attempt 4 copies the timing
of another open-source client of this flow, 60 seconds before expiry.
Attempts 5 to 7 show the optional fields do not rescue a refused token. They
reused attempt 4's token, so a first request carrying `ext_agent_host_id` or
`scope` is still untested.

## Ruled out

- **Request shape.** It matches the documented request. Two other
  open-source clients of this flow send the same fields.
- **Endpoint.** It is the `token_endpoint` from
  `https://auth.openai.com/.well-known/openid-configuration`, whose
  `grant_types_supported` lists `refresh_token`. The same endpoint accepts
  our authorization-code exchange.
- **Client id.** The issued `oaiapp_` id the callback returned, saved with
  the token set.
- **Clock.** The client clock was within a second of the `Date` header from
  `auth.openai.com`.
- **Encoding.** Every value is percent-encoded per RFC 3986.
- **Concurrency.** One refresher, serialized by a file lock; no other
  process held the token.
- **Grant.** The granted scopes include `offline_access` and
  `chatgpt.tokens.use.direct`, and the token response included
  `refresh_token` and `earliest_refresh_at`.

## Questions

1. Does a refresh need anything beyond the documented fields, for example
   `ext_agent_host_id`? Attempts 5 to 7 tried it, `scope`, and no
   `resource`, but only after attempt 4 had been refused.
2. Could `invalid_grant` on refresh carry an `error_description` saying why?
3. The issued client id and the exact UTC time of each attempt are
   available privately.
