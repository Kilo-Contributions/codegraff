#!/usr/bin/env python3
"""Offline subprocess coverage of graff's external-TUI launcher boundary."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def fixture(path, label):
    path.write_text(
        f"#!{sys.executable}\n"
        "import json, os, sys\n"
        f"print(json.dumps({{'label': {label!r}, 'args': sys.argv[1:], "
        "'pid': os.getpid(), 'stdin': sys.stdin.read()}))\n"
        "print('ui-stderr', file=sys.stderr)\n"
        "sys.exit(23)\n"
    )
    path.chmod(0o755)


def run(binary, args, env):
    proc = subprocess.Popen(
        [str(binary), *args], env=env, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        out, err = proc.communicate("ui-input", timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        raise
    return proc.pid, proc.returncode, out, err


def main():
    if os.name == "nt":
        print("external TUI: POSIX exec fixture skipped on Windows")
        return
    with tempfile.TemporaryDirectory(prefix="graff-external-ui-") as tmp:
        root = Path(tmp)
        install, path_dir = root / "install", root / "path"
        install.mkdir()
        path_dir.mkdir()
        binary = install / "graff"
        shutil.copy2(Path(sys.argv[1]).resolve(), binary)
        env = {
            "HOME": str(root), "PATH": str(path_dir),
            "GRAFF_NO_TELEMETRY": "1", "NO_COLOR": "1",
            # A forwarded UI command must run even when engine setup would fail.
            "GRAFF_MAX_MODEL_CALLS": "not-an-engine-invocation",
        }
        sibling = install / "graff-tui"
        fixture(sibling, "sibling")
        fixture(path_dir / "graff-tui", "path")
        args = ["tui", "--help", "--ui-only-flag", "two words", ""]
        for expected in ("sibling", "path"):
            pid, code, out, err = run(binary, args, env)
            assert code == 23, (code, out, err)
            payload = json.loads(out)
            assert payload == {
                "label": expected, "args": args[1:],
                "pid": pid, "stdin": "ui-input",
            }, payload
            assert err == "ui-stderr\n", err
            if expected == "sibling":
                sibling.unlink()
        (path_dir / "graff-tui").unlink()
        _, code, out, err = run(binary, ["tui"], env)
        assert code != 0 and "graff-tui is not installed" in err, (code, out, err)
        assert "No files were downloaded" in err, err
        assert not (root / ".graff").exists()
        fixture(sibling, "not-a-prompt")
        env.pop("GRAFF_MAX_MODEL_CALLS")
        _, code, out, err = run(binary, ["-p", "tui", "--help"], env)
        assert code == 0 and "not-a-prompt" not in out, (code, out, err)
    print("external TUI: sibling precedence, PATH fallback, argv/stdio/exec status, missing install, and prompt escape passed")


if __name__ == "__main__":
    main()
