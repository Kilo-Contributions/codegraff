#!/usr/bin/env python3
"""Build one release-matrix target through nanocompile's declared-task cache."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

TARGETS = ("aarch64-macos", "x86_64-macos", "x86_64-linux", "aarch64-linux",
           "x86_64-windows", "aarch64-windows")
ROOT = Path(__file__).resolve().parents[1]


def files(root):
    return sorted({str(p.resolve()) for p in root.rglob("*") if p.is_file()})


def contract(target, version, zig, telemetry=None):
    # A fixed version avoids an undeclared dependency on git describe / .git.
    output = ROOT / "zig-out" / target / "bin" / ("graff.exe" if target.endswith("windows") else "graff")
    command = [str(zig), "build", "graff", "-Doptimize=ReleaseFast",
               "-Dtarget=" + target, "-Dversion=" + version,
               "--prefix", str(ROOT / "zig-out" / target)]
    if telemetry is not None:
        command.append("-Dtelemetry-endpoint=" + telemetry)
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    inputs = {str(ROOT / p) for p in tracked if p and (ROOT / p).is_file()}
    inputs.add(str(Path(__file__).resolve()))
    # Zig 0.17 fetches its pinned package tree here. Include content, not just
    # the dependency lock: local package edits must invalidate a task restore.
    inputs.update(files(ROOT / "zig-pkg"))
    description = subprocess.check_output([str(zig), "env"], text=True)
    match = re.search(r'\.lib_dir = "([^"]+)"', description)
    if not match:
        raise RuntimeError("Cannot identify the selected Zig library tree")
    resources = {str(zig)}
    resources.update(files(Path(match.group(1))))
    # On macOS the selected SDK is another installed tool resource. Linux
    # matrix runners cross-link using Zig's bundled libraries instead.
    if sys.platform == "darwin":
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        resources.update(files(Path(sdk)))
    return {"schema": 1, "tasks": [{"name": "graff-" + target, "cwd": str(ROOT),
            "command": command, "inputs": sorted(inputs), "outputs": [str(output)],
            "tool_resources": sorted(resources)}]}, output


def environment(cache):
    # Run IDs, CI tokens and incidental shell variables must neither reach the
    # compiler nor perturb its key. Every retained value is still keyed by Nano.
    return {"PATH": os.defpath, "HOME": str(Path.home()), "LANG": "C", "LC_ALL": "C",
            "TZ": "UTC", "NANOCOMPILE_DIR": str(cache),
            "ZIG_GLOBAL_CACHE_DIR": str(ROOT / ".zig-global-cache"),
            "ZIG_LOCAL_PKG_DIR": str(ROOT / "zig-pkg")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True, choices=TARGETS)
    parser.add_argument("--version", required=True)
    parser.add_argument("--telemetry-endpoint")
    parser.add_argument("--nanocompile", default=os.environ.get("NANOCOMPILE_EXE"))
    parser.add_argument("--verify-restore", action="store_true",
                        help="remove the built output and prove a byte-identical cache hit")
    args = parser.parse_args()
    zig = Path(shutil.which("zig") or "zig").resolve()
    cache = Path(os.environ.get("NANOCOMPILE_DIR", ROOT / ".nanocompile-cache")).resolve()
    env = environment(cache)
    subprocess.run([str(zig), "build", "--fetch=all"], cwd=ROOT, env=env, check=True)
    spec, output = contract(args.target, args.version, zig, args.telemetry_endpoint)
    if not args.nanocompile:
        if args.verify_restore:
            parser.error("--verify-restore requires --nanocompile or NANOCOMPILE_EXE")
        return subprocess.call(spec["tasks"][0]["command"], cwd=ROOT, env=env)
    binary = str(Path(args.nanocompile).resolve())
    spec_path = ROOT / ".zig-cache" / ("nanocompile-" + args.target + ".json")
    spec_path.parent.mkdir(parents=True, exist_ok=True)
    spec_path.write_text(json.dumps(spec, sort_keys=True) + "\n")
    command = [binary, "task", str(spec_path)]
    subprocess.run(command, cwd=ROOT, env=env, check=True)
    if args.verify_restore:
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        events = cache / "events"
        offset = events.stat().st_size if events.exists() else 0
        output.unlink()
        subprocess.run(command, cwd=ROOT, env=env, check=True)
        with events.open("rb") as source:
            source.seek(offset)
            if b"task_hit\n" not in source.read():
                raise RuntimeError("nanocompile did not report a task cache hit")
        if hashlib.sha256(output.read_bytes()).hexdigest() != digest:
            raise RuntimeError("nanocompile restored different artifact bytes")
        print("Verified byte-identical nanocompile restore:", args.target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
