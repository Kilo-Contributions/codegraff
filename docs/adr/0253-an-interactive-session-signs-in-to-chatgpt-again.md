# 0253. An interactive session signs in to ChatGPT again by itself

Status: accepted 2026-10-04. Builds on 0221 and 0229.

## Context

The ChatGPT sign-in (0221, 0229) issues an access token that lasts an hour and
a refresh token to renew it. The token endpoint currently answers every
renewal with `invalid_grant`, including requests that match the documented
refresh request field for field and the reference implementations that send
it. So a sign-in lasts about an hour. When it lapses, the next request fails
with "sign in again with `graff login chatgpt`", the turn ends, and the person
has to run the sign-in and repeat the request.

A sign-in after the first is short: graff reuses the issued app registration
and fills in the account, so with a live browser session it is one click.

## Decision

- When a ChatGPT request's credential is rejected and the refresh cannot
  replace it, a session with a person at the terminal opens the same browser
  sign-in as `/login chatgpt`, waits up to three minutes, adopts the new token
  and retries the request once.
- Only an interactive root session does this. `-p`, piped and `--json` runs,
  ACP sessions (the client owns sign-in) and sub-agents never open a browser;
  they fail as before.
- A sign-in that does not finish ends it for the process. Later requests fail
  with the usual error instead of reopening the browser.
- The refresh path is unchanged: graff still renews inside the window OpenAI
  allows, so renewals start working again with no change here once the token
  endpoint accepts them.

## Consequences

An expired sign-in costs one click in the browser instead of a failed turn.
A person who walks away from a long task still finds it stopped at the first
request after expiry, now with the sign-in waiting in the browser for three
minutes before the request fails.
