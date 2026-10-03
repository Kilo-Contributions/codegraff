# Zig 0.17 migration

**Status: on the stable Zig 0.17.0 release.** CodeGraff moved to the
development build `0.17.0-dev.813+2153f8143` for v0.0.210 and to the stable
`0.17.0` release once it shipped. The exact version is pinned: a moving pin
would make CI and releases non-reproducible.

## Select the toolchain

```sh
zigup 0.17.0
zig version
```

The second command must print `0.17.0`. The same exact value is used by
`build.zig.zon`, the installers, CI, Windows CI, and release builds. The CI
installer (`scripts/install-zig-ci.py`) pins each platform's archive, `zig`
binary and extracted-tree SHA-256.

## From the development build to 0.17.0

- The optimize modes are lowercase fields (`.debug`, `.safe`, `.fast`,
  `.small`); `build.zig` and `builtin.mode` checks use them. The old names
  remain only as deprecated declarations, and `-Doptimize=ReleaseFast` still
  parses.
- `zig fmt` rewrites renamed builtins, for example `@intFromEnum` to
  `@backingInt`; the reformatted files are part of the move.
- `std.crypto`: `X25519.KeyPair.generateDeterministic` and
  `X25519.recoverPublicKey` no longer return error unions, and RSA PKCS#1 v1.5
  `verify`/`concatVerify` take the signature by pointer.
- The unmanaged `ArrayList` has a `pointer_stability` field, so tests build a
  list from a slice with `.fromOwnedSlice`.
- The `accord` and `http-zig` dependencies are pinned to their `zig-0.17.0`
  branches, which carry the same changes.

## From Zig 0.16 to the development build

- Replaced the removed `b.build_root` Build API field.
- Replaced the removed `**` array/string repetition operator with `@splat` and
  a small comptime `repeatBytes` helper.
- Replaced `std.meta.fields` with `std.meta.fieldNames`.
- Replaced `Allocator.dupeZ` with `Allocator.dupeSentinel`.
- Replaced the removed `std.ascii.indexOfIgnoreCase` with a local helper.
- Vendored Zigzag 0.1.2 because its upstream build script still reads the
  removed `b.args` field. Only its library module is exported locally.
- Strip ReleaseFast and ReleaseSmall artifacts at link time. This keeps
  ReleaseFast code generation while reducing the arm64 macOS binary from
  3,264,664 bytes to 2,735,544 bytes.

## Measured result

On arm64 macOS, warm local startup remains at the process-launch floor:
approximately 1.8 ms for `--version` and `--schema`. Zig 0.17 and Zig 0.16 are
within measurement noise on these paths. The model/tool loop remains primarily
network and subprocess bound, so no unsupported 30–40× runtime claim is made.

ReleaseSmall was also measured at 1,473,592 bytes, but it was roughly 4–5%
slower on the local startup paths. The release therefore stays on stripped
ReleaseFast: 16.2% smaller than unstripped ReleaseFast without intentionally
trading away runtime speed.

## Validation

- [x] `zig build`
- [x] `zig build test --summary all` (227 tests)
- [x] full deterministic Python/PTY integration matrix
- [x] SDK regeneration drift check
- [x] all six release cross-target builds
- [x] signed and notarized macOS release artifacts

## Rollback

`zigup` keeps older toolchains installed, so historical builds can still run
with `zigup run 0.17.0-dev.813+2153f8143 build` (or `zigup run 0.16.0 build`
for older tags). Current development and releases must use Zig 0.17.0.
