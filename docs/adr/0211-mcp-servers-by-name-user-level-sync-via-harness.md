# 0211. MCP servers are added by name, kept user-level, and synced by Harness

Status: accepted 2026-09-28

## Context

Adding an MCP server meant finding its URL or package, writing `.mcp.json` by
hand, and repeating that in every project and on every machine. `graff mcp add`
now infers an entry from a URL, a package, or a pasted JSON block, and verifies
it by connecting (#1362). Three questions were still open: what a bare name
like `linear` should resolve to, where an entry meant for every project lives,
and how a person's servers reach their other machines and the Harness app.

Several answers were tried and dropped:

- Syncing the user-level file as one end-to-end encrypted vault item (#1371)
  worked in tests. But it required `graff keys enable` on every device and a
  Harness bearer in every process, and it duplicated the cross-device sync
  Harness already runs.
- Holding MCP OAuth tokens on codegraff.com and handing devices short-lived
  access tokens would have made one sign-in cover every device. But the site
  would hold long-lived third-party refresh tokens, and some vendors issue
  access tokens that do not expire soon.
- A separate agent-messaging service for coordination was dropped in favour of
  channels that already exist.

## Decision

- **Names.** `graff mcp add <name>` resolves the name against the curated
  catalog published at `https://codegraff.com/mcp.json`, by slug or alias.
  Every entry there was connected with graff before it was listed. A name the
  catalog lacks goes to the official MCP registry. There, graff picks a server
  only when its verified namespace owner (`com.<name>` or `io.github.<name>`)
  equals the name; any other match is listed for the person to choose, never
  run. A catalog entry can declare required env vars or headers. Nothing is
  saved until `--env` / `--header` (or, for env vars, the environment)
  supplies them. An entry with a known limitation explains it instead of
  saving.
- **Scope.** `graff mcp add … --everywhere` writes the user-level
  `~/.codegraff/mcp.json`, which every workspace already merges below its
  project `.mcp.json` (#345). The default stays project-local.
- **Sync.** The Harness engine syncs the user-level file through its existing
  workspace registry sync. Each server is one row keyed by name, with
  per-field last-write-wins and a tombstone for removal. Rows carry the
  non-secret projection only: `url`, or `command` and `args`, plus the *names*
  of required env vars and headers. graff does not implement sync itself. When
  the file changes under a running session, the config watcher joins the new
  servers.
- **Secrets stay on the device.** Env values, header values, and MCP OAuth
  tokens never leave the machine that holds them. Each device signs in to an
  OAuth server itself. Refresh tokens move to the OS credential store where
  graff has one (the macOS Keychain first), and graff reports where it saved
  them. Existing credential files are moved in on first read and then deleted.
  When a synced server needs a value this device lacks, graff names it on
  first use.
- **Harness talks to graff only over ACP.** Adding a server is the `/mcp add`
  slash command. An OAuth sign-in that a server needs mid-turn goes through
  ACP form elicitation: a form carrying the sign-in link and a required
  boolean. graff switches to URL-mode elicitation when the client advertises
  it. Sign-in is never attempted at session start, because clients cancel
  elicitations that arrive outside a turn. Server status is reported as
  `_meta["graff/mcp"]` (`[{name, state, tools}]`) on the `session/new`
  response and on updates, not as config options, which clients render as
  editable controls.

## Consequences

One command adds a known server, and one flag makes it follow the person to
every project. Machines running Harness converge on the same server list
without a second sync system, a vault enrollment step, or new credentials.

Machines without Harness do not sync; the user-level file is theirs to manage.
Server names, URLs and commands are visible to the Harness sync service;
secrets are not. Signing in once per device is the cost of keeping tokens
off shared infrastructure. Vendors that only accept pre-registered
confidential OAuth clients remain unsupported for the same reason.

The catalog is a curated, hand-verified list that can go stale, and a name
that resolves differently tomorrow changes what `mcp add` saves. Entries are
pinned only as far as their publishers' URLs and package names are stable.
Revisit the sync decision if graff needs to sync without Harness, or if
Harness's registry gains end-to-end encryption, which would let secrets
travel too.
