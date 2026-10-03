# 0245. Fullscreen TUI is an external client

Status: accepted 2026-10-02

Supersedes ADR 0041, ADR 0042 and the fullscreen portion of ADR 0142.

## Context

The fullscreen terminal UI is maintained separately. Keeping its former Zig renderer and in-process adapters here leaves a second implementation to build, test and maintain alongside the engine and line REPL.

## Decision

Remove the embedded `TUI/` implementation, its `src/tui*` adapters, build targets and UI-specific regression tooling. Keep shared engine behavior, ACP, the line REPL and its terminal checks here; rendering coverage belongs with the separate client.

`graff tui [args...]` launches an installed `graff-tui` before argument parsing, credentials, MCP or session creation. Resolve beside the running executable first, then on `PATH`, and forward the remaining arguments unchanged. POSIX uses process replacement; Windows inherits standard handles and waits for the child. Missing installations fail with installation guidance, without downloads or engine startup. `graff -p "tui"` remains a prompt.

TTY `graff repl` uses the normal line REPL; piped `graff repl` keeps its scripted model. No engine path claims the fullscreen client's alternate screen.

## Consequences

The default build installs only `graff`, and `tui-test` is retired. Launcher subprocess tests use fake executables to cover lookup order, argument and standard-stream forwarding, process replacement, exit status and missing installations without starting a real UI.

The unit-count floor is adjusted for removed adapter tests, not weakened to hide unreachable engine tests. Automatic verified downloads and compatibility negotiation from #1444 remain separate work: no release-asset contract is invented here, and the installed-only launcher works offline.
