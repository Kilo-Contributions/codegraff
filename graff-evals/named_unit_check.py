#!/usr/bin/env python3
"""Grade named Zig unit tests by running them (ADR 0214, mined tasks).

Builds only the unit-test binary, filtered to the named tests
(`zig build test-bin -Dtest-filter=…`), runs it, and reads each test's own
result line (`N/M module.test.<name>...OK`). Every name must have run and
passed. A name that never ran fails: a test the module graph does not reach
proves nothing. Integration scripts are not run, so an unrelated flaky
script cannot fail the grade, and a compile error is reported as such.

    named_unit_check.py NAME [NAME ...]      # exit 0 iff all ran and passed
"""
from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile


def parse(output: str, name: str) -> str:
    """pass / fail / missing for one name in a test binary's output."""
    ran = re.compile(r"\.test\." + re.escape(name) + r"\.\.\.(\S+)")
    verdicts = [m.group(1) for m in ran.finditer(output)]
    broke = re.compile(r"error: '[^'\n]*\.test\." + re.escape(name) + r"' (?:failed|terminated)")
    if broke.search(output) or any(v.startswith(("FAIL", "SKIP")) for v in verdicts):
        return "fail"
    if any(v.startswith("OK") for v in verdicts):
        return "pass"
    # Started but never reached a verdict: a crash (a segfault aborts the
    # binary mid-line). It ran and failed; calling it missing sent a reader
    # looking for an unreachable test instead of a crashing fix.
    return "crashed" if verdicts else "missing"


def grade(cwd: str, names: list[str], timeout: int = 600) -> dict[str, str]:
    # A private cache dir: the only test binary in it is the one just built
    # for exactly these filters (a shared cache can hand back another run's).
    cache = tempfile.mkdtemp(prefix="named-unit-check-")
    try:
        build = subprocess.run(["zig", "build", "test-bin", "--cache-dir", cache,
                                *[f"-Dtest-filter={n}" for n in names]],
                               cwd=cwd, capture_output=True, text=True, timeout=timeout)
        found = glob.glob(os.path.join(cache, "o", "*", "test"))
        if build.returncode != 0 or not found:
            return {n: "compile-error" for n in names}
        try:
            run = subprocess.run([max(found, key=os.path.getmtime)], cwd=cwd,
                                 capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return {n: "fail" for n in names}
        out = (run.stdout or "") + "\n" + (run.stderr or "")
        return {n: parse(out, n) for n in names}
    finally:
        shutil.rmtree(cache, ignore_errors=True)


def self_test() -> None:
    out = ("3/5 acp_elicit.test.decline, cancel (#1322)...OK\n"
           "4/5 ask_user.test.noAnswerText keeps cancel...FAIL (TestExpectedEqual)\n"
           "5/5 other.test_0...OK\n")
    assert parse(out, "decline, cancel (#1322)") == "pass"
    assert parse(out, "noAnswerText keeps cancel") == "fail"
    assert parse(out, "never compiled in") == "missing"
    crash = "error: 'x.test.boom' terminated with signal ABRT with stderr:\n"
    assert parse(crash, "boom") == "fail"
    segv = "3/74 m.test.joinWithin: stays queued...Segmentation fault at address 0x138\n"
    assert parse(segv, "joinWithin: stays queued") == "crashed"
    print("named_unit_check self-test ok")


def main() -> None:
    if sys.argv[1:] == ["self-test"]:
        return self_test()
    names = sys.argv[1:]
    if not names:
        raise SystemExit("usage: named_unit_check.py NAME [NAME ...]")
    verdicts = grade(".", names)
    for n, v in verdicts.items():
        print(f"{v:14} {n}")
    raise SystemExit(0 if all(v == "pass" for v in verdicts.values()) else 1)


if __name__ == "__main__":
    main()
