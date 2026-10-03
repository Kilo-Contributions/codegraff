# 0242. The shell tool names python3's version

Status: accepted 2026-10-03

## Context

ADR 0234 made the `shell` tool name the OS its commands run on. Models also
assume a recent python3: in eval traces they wrote
`datetime.fromisoformat("...Z")`, which needs 3.11, on a Mac whose `python3`
is the system 3.9. The script failed and the model spent a whole call
rewriting it. Another harness on the same tasks avoided this only because its
model happened to compute in JavaScript.

Running `python3 --version` at startup would tell us, but on a Mac without
the developer tools `/usr/bin/python3` opens an install dialog, and a startup
probe must not do that.

## Decision

At startup graff finds the first `python3` on `PATH` (the one a shell command
runs) and reads its version from the resolved path: `.../Versions/3.9/...`,
`python3.11`, `python@3.12`. macOS's `/usr/bin/python3` launcher is followed
to the developer tools' interpreter it runs, when one is installed. Nothing
is executed. When the version is found, the shell tool's OS clause says so:
"python3 is 3.9, so scripts must run on 3.9". When the path names no version
(a pyenv shim, say) or there is no python3, the description is unchanged.

The version is read once per process, so the catalog bytes stay stable for
the whole session. The root catalog and licensed workers' rendered catalogs
carry it; the compiled-in subagent catalog does not.

## Consequences

The tool catalog differs between machines with different python3 versions,
which is the point, and is invisible to the prompt cache within one machine.
A PATH change mid-session is not seen. Revisit if traces show version errors
in subagents, or interpreters whose path never names a version becoming
common.
