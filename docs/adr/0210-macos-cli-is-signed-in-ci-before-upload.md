# 0210. The macOS CLI is signed and notarized in CI before upload

Status: accepted 2026-09-28

## Context

Tag releases built every CLI tarball on Linux and uploaded them to a draft.
The macOS halves were then signed and notarized by hand on a configured Mac
(docs/notarization.md), which re-uploaded the tarballs and a hand-edited
`SHA256SUMS` over the originals. That replace step is not atomic: a
maintainer can publish in the middle of it, and the workflow also attaches to
a release that was already published. Either way users could download an
unsigned binary, or a signed one whose checksum line is still the old one.

## Decision

- `release.yml` is `build` → `macos-sign` → `release` → `desktop-linux`.
  `macos-sign` runs on a macOS runner and signs each bare `graff` with the
  Developer ID Application identity (hardened runtime, secure timestamp),
  notarizes it with an App Store Connect API key, and fails unless the
  notarytool status is `Accepted`. Bare CLIs are not stapled.
- It runs only when `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `AC_API_KEY_P8`,
  `AC_API_KEY_ID` and `AC_API_ISSUER_ID` are all set. Otherwise it succeeds
  as a no-op, the release carries the unsigned macOS tarballs, and the
  manual runbook remains the path.
- Nothing is uploaded until signing is done. `SHA256SUMS` is computed once in
  `release` from the bytes being uploaded; CI never edits it afterwards.
- The macOS desktop app stays on `distribute.sh` + `publish-updates.sh` from a
  configured Mac (ADR 0079, 0157). CI does not build it for release: DMG
  layout drives Finder via AppleScript, `distribute.sh` takes a notarytool
  keychain profile, the optional passkey provisioning profile is a local
  file, and the update assets must reach the draft together.

## Consequences

A tag with the secrets produces a draft whose macOS tarballs are already
notarized; do not re-sign them by hand, since that changes the bytes Apple
scanned. A notarization failure blocks the whole draft, Linux and Windows
included, until the failed jobs are re-run. Every release now also waits for
a macOS runner, even when it only no-ops. Beta prereleases still ship an
unsigned macOS CLI; revisit if they should share this job.
