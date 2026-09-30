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

The three other open-source clients of this flow we found send the same
request ([Other clients](#other-clients)), so their sign-ins should end after
an hour too.

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

## What we tried

None of these changed the answer.

- **Timing.** Before `earliest_refresh_at` (attempt 1), a minute after it
  (3), 60 seconds before expiry (4) and after expiry (2 and 8).
- **Fresh tokens.** Never-used refresh tokens from three separate sign-ins
  (attempts 1, 3 and 4).
- **Optional fields.** `ext_agent_host_id`, `scope`, and no `resource`
  (attempts 5 to 7, with the caveat above).
- **Two HTTP clients.** graff's own renewal (attempt 3, and again just after
  attempt 8) and a standalone script (attempts 4 to 8, in
  [Reproducing it](#reproducing-it)).
- **Request shape.** It matches the documented request, and the three other
  open-source clients of this flow send the same fields
  ([Other clients](#other-clients)).
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

## Reproducing it

What we used, in order:

1. **Sign in** with any client below. graff: `graff login chatgpt-new`, which
   saves the token set with the issued `client_id`, `expires_at` and
   `earliest_refresh_at` ([ADR 0221](../adr/0221-chatgpt-new-sign-in.md)).
2. **Stop that client**, so nothing else renews or replays the refresh token.
3. **Wait for the renewal window**, then send the [curl above](#request) or
   run the script below. It sends the documented request and, only if that
   is refused, the three variants with the same token. It prints each status,
   OpenAI's JSON answer, `x-request-id` and `cf-ray`, and the refresh token
   only as a fingerprint. A renewal that works is saved back to the record.

```sh
python3 refresh_repro.py chatgpt-new.json expiry-60   # or window, after-expiry, now
```

```python
#!/usr/bin/env python3
"""Renew a Sign in with ChatGPT token set the documented way, then with variants.

usage: python3 refresh_repro.py RECORD.json [expiry-60 | window | after-expiry | now]

RECORD.json holds client_id, refresh_token, expires_at and earliest_refresh_at
(Unix seconds), plus ext_agent_host_id and scopes if you have them; graff's
chatgpt-new.json has all of them. Stop the client that owns the sign-in first.
The variants go out only if the documented request is refused, with the same
token. Prints statuses, OpenAI's answers and request ids, and the refresh token
only as a fingerprint. A renewal that works is saved back to RECORD.json.
"""
import hashlib, json, os, sys, time, urllib.error, urllib.parse, urllib.request

URL = "https://auth.openai.com/api/accounts/oauth/token"
RESOURCE = "https://api.openai.com/v1"
path, when = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "expiry-60")
r = json.load(open(path))


def fp(s):
    return hashlib.sha256(s.encode()).hexdigest()[:10] if s else "(empty)"


def post(fields):
    req = urllib.request.Request(URL, data=urllib.parse.urlencode(fields).encode(), headers={
        "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return res.status, json.loads(res.read() or b"{}"), res.headers
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw), e.headers
        except ValueError:
            return e.code, {"unparsed": raw[:200].decode("utf8", "replace")}, e.headers


at = {"expiry-60": r["expires_at"] - 60, "window": r["earliest_refresh_at"] + 60,
      "after-expiry": r["expires_at"] + 30, "now": 0}[when]
if at > time.time():
    print(f"waiting {int(at - time.time())}s ({when})", flush=True)
    time.sleep(at - time.time())

documented = {"grant_type": "refresh_token", "client_id": r["client_id"],
              "refresh_token": r["refresh_token"], "resource": RESOURCE}
attempts = [("documented", documented)]
if r.get("ext_agent_host_id"):
    attempts.append(("+ ext_agent_host_id", {**documented, "ext_agent_host_id": r["ext_agent_host_id"]}))
attempts.append(("without resource", {k: v for k, v in documented.items() if k != "resource"}))
if r.get("scopes"):
    attempts.append(("+ scope", {**documented, "scope": " ".join(r["scopes"])}))

for label, fields in attempts:
    now = int(time.time())
    status, body, headers = post(fields)
    answer = {k: v for k, v in body.items() if k in ("error", "error_description", "unparsed")}
    print(f"{label}: {status} {json.dumps(answer)} request_id={headers.get('x-request-id', '')} "
          f"cf_ray={headers.get('cf-ray', '')} expires_in={r['expires_at'] - now}s "
          f"since_earliest={now - r['earliest_refresh_at']}s refresh={fp(r['refresh_token'])}", flush=True)
    if status == 200 and body.get("access_token"):
        r.update(access_token=body["access_token"], refresh_token=body.get("refresh_token") or r["refresh_token"],
                 expires_at=now + int(body.get("expires_in", 3600)))
        if isinstance(body.get("earliest_refresh_at"), (int, float)):
            r["earliest_refresh_at"] = int(body["earliest_refresh_at"])
        tmp = path + ".tmp"
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            json.dump(r, f)
        os.replace(tmp, path)
        print(f"renewed: refresh {fp(documented['refresh_token'])} -> {fp(r['refresh_token'])}, saved to {path}")
        break
```

To watch graff's own renewal instead, keep graff signed in past
`earliest_refresh_at` and send any request. graff renews 5 minutes before
expiry, and when OpenAI refuses it keeps the answer in the record as
`last_refresh_error`.

## Other clients

Four open-source clients ship this flow, graff included. All four send the
same four fields to the same endpoint and differ only in when they renew. We
have not run the other three; the snippets are their source at the linked
commits.

| Client | Renews | When the renewal is refused |
|---|---|---|
| graff | 5 minutes before expiry, never before `earliest_refresh_at` | Keeps OpenAI's answer and asks for a new sign-in once the access token expires |
| T3 Code | 60 seconds before expiry, never before `earliest_refresh_at` | Deletes the connection: "Your ChatGPT connection expired or was disconnected. Sign in again." |
| pi | 3 minutes before expiry | Throws `OpenAI OAuth token request failed (400): ...` |
| nolune | 5 minutes before expiry, never before `earliest_refresh_at` while the token works | Ends the sign-in and asks for a new one |

**graff**, [`src/oauth_chatgpt.zig`](../../src/oauth_chatgpt.zig#L474):

```zig
const body = form(arena, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", r.client_id }, .{ "refresh_token", r.refresh }, .{ "resource", resource } }) catch return null;
```

**T3 Code** (pingdotgg/t3code, merged in #14290),
[`apps/server/src/provider/CodexChatGptAuth.ts`](https://github.com/pingdotgg/t3code/blob/0fcd5f90611451cca842689faea53b5450c022da/apps/server/src/provider/CodexChatGptAuth.ts#L729-L748). On
`invalid_grant` it removes the connection ([L391-L406](https://github.com/pingdotgg/t3code/blob/0fcd5f90611451cca842689faea53b5450c022da/apps/server/src/provider/CodexChatGptAuth.ts#L391-L406)).

```ts
const now = yield* Clock.currentTimeMillis;
if (record.expiresAt - now > 60_000) return record;
if (record.earliestRefreshAt !== null && record.earliestRefreshAt > now) {
  if (record.expiresAt > now) return record;
  // ...
}
// ...
const tokens = yield* exchange(
  new URLSearchParams({
    grant_type: "refresh_token",
    client_id: record.clientId,
    refresh_token: record.refreshToken,
    resource,
  }),
)
```

**pi** (earendil-works/pi),
[`packages/ai/src/auth/oauth/openai-chatgpt.ts`](https://github.com/earendil-works/pi/blob/1b347794e2a630e4359f2584f4eea388145d0ddf/packages/ai/src/auth/oauth/openai-chatgpt.ts#L208-L223), with
`TOKEN_URL` and `RESOURCE` at [L20-L21](https://github.com/earendil-works/pi/blob/1b347794e2a630e4359f2584f4eea388145d0ddf/packages/ai/src/auth/oauth/openai-chatgpt.ts#L20-L21):

```ts
const token = await requestToken(
  new URLSearchParams({
    grant_type: "refresh_token",
    client_id: clientId,
    refresh_token: credential.refresh,
    resource: RESOURCE,
  }),
  signal,
);
```

**nolune** (triangle-int/nolune, merged in #81),
[`packages/core/src/chatgpt-sign-in.ts`](https://github.com/triangle-int/nolune/blob/d901ecb94a13cd8a623c087ca239f54cb4318ded/packages/core/src/chatgpt-sign-in.ts#L760-L781). Its own test pins
the same four fields.

```ts
// OpenAI says when refreshing is useful; until then the token in hand still works.
if (usable && r.earliestRefreshAt && now < r.earliestRefreshAt) return r.accessToken!;
// ...
response = await postForm(endpoints().token, {
  grant_type: 'refresh_token',
  client_id: r.clientId,
  refresh_token: r.refreshToken,
  resource: API_RESOURCE
});
```

opencode's ChatGPT sign-in uses the Codex CLI's client and `/oauth/token`
without `resource`, so it does not go through this flow.

## Questions

1. Does a refresh need anything beyond the documented fields, for example
   `ext_agent_host_id`? Attempts 5 to 7 tried it, `scope`, and no
   `resource`, but only after attempt 4 had been refused.
2. Could `invalid_grant` on refresh carry an `error_description` saying why?
3. The issued client id and the exact UTC time of each attempt are
   available privately.
