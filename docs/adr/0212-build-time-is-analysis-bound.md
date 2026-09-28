# 0212. Build time is analysis-bound: keep the default backend, filter test builds

Status: accepted 2026-09-28

## Context

A cold `zig build` of graff takes about 16 s and a cold `zig build test-bin`
about 44 s (Zig 0.17.0-dev.813, Debug, Apple silicon). The question was
whether redundant files were inflating that, and what could make it faster.

An audit of the import graph from every root in `build.zig`:

- 825 `.zig` files. 649 (8.6 MB) are reachable from the shipped binaries;
  175 (2.0 MB) only from `test` blocks; none from nothing.
  `src/shell_identity_probe.zig` looks unreferenced from Zig but is built on
  its own by `scripts/eval-tier1.sh`.
- No two files have identical content. No single file is outsized.
- The spec JSON under `spec/kernels/` (1.1 MB) is embedded only into the unit
  test binary. `libgraff` and the wasm core are opt-in steps, not part of the
  default install.
- Six `*_test.zig` / `*_tests.zig` files are imported at the top level of
  normal code. Zig analyzes only what is referenced and `test` blocks only in
  test builds, so the binary pays for parsing them and nothing else.

Measurements, each cold (fresh local cache) and run one at a time:

| Build | Time |
|---|---|
| `graff`, default backend | 16 s |
| `graff`, analysis only (`-fno-emit-bin`) | 17 s |
| `graff`, `-fllvm` | 36 s |
| No-op rebuild | 0.2 s |
| `test-bin`, all tests | 44 s |
| `test-bin`, one `-Dtest-filter` | 13 s |

Analysis-only takes as long as the full build: semantic analysis of the code
actually used is the whole cost, and it runs on one core. Code generation and
linking with the default backend are nearly free.

Tried and rejected:

- `-fllvm`: twice as slow in Debug.
- `-fincremental`: its state does not persist across separate `zig build`
  invocations, so each edit still re-analyzes everything. Under
  `zig build --watch -fincremental`, a comment edit took 15 s to rebuild and a
  one-function change 70 s: slower than a cold build.
- `-fno-llvm -fno-lld` (self-hosted backend without lld): memory grew without
  bound, past 150 GB, and took the host down. Do not use it on this codebase.

## Decision

- Keep the default backend for Debug builds. Do not add `-fllvm`,
  `-fincremental`, or `-fno-llvm -fno-lld` to `build.zig` or scripts.
- No file removal: there is no dead weight to cut. Size is not the lever;
  analyzed code is.
- While iterating, build unit tests with `-Dtest-filter=<name>` (about 3x
  faster). `test-bin` only compiles; run the resulting test binary to execute
  the filtered tests. Leave the full suite to the pre-push hook and CI.
- Run build-time experiments one at a time, never in parallel, and watch
  memory.

## Consequences

A cold build stays around 16 s and each edit re-analyzes the whole binary.
Faster iteration comes from filtered test builds, not from build flags.
Revisit when a Zig upgrade makes `-fincremental` persist across invocations,
or makes `--watch` rebuilds faster than cold ones, and re-check the
self-hosted backend's memory before trying it again.
