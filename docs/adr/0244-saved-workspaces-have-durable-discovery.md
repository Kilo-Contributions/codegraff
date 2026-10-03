# 0244. Saved workspaces have durable device-local discovery

Status: accepted 2026-10-02

## Context

The live registry exposes sessions in unrelated repositories, while saved-session discovery covered only cwd, linked worktrees and home. A visible session could not be resumed, and removing the live process removed the only clue to its location (#1457–#1462).

## Decision

Remember workspace roots in a device-local index when saving meaningful conversation state. Use a separate file per root so unrelated saves do not race on a shared read-modify-write document. Discover saves in those roots without recursively scanning the device. The index contains paths, not conversation contents.

Absolute `.graff/sessions/KEY.session.json` paths are explicit resume targets. Pickers and listings use these for remote saves so equal keys in different workspaces remain selectable. Bare keys retain cwd-first compatibility. Qualified resume enters the selected workspace before restoring history and refuses to proceed if entering fails. Home-origin saves retain ADR 0059's history-only behavior.

ACP `session/load` retains its explicit client-cwd contract (ADR 0202); a client selects a remote save with that workspace and its basename. Slash-command resume and the TUI use the same engine discovery and restore paths.

## Consequences

Saved roots remain discoverable after their processes exit. Existing unindexed roots can be reached by an explicit target and become indexed on their next save. Stale roots contribute no rows; no global filesystem crawl or copying session files is required. The local index is metadata and must not be published.
