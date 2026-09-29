#!/usr/bin/env python3
"""Real-PTY regression for #1278: /loop holds for its own background work.

A /loop turn that starts a background shell job yields the prompt at once
(subagent_interactive), so the turn makes no further model call and the
controller used to read it as `idle` and end the run. The job's completion
wake then ran as an ordinary turn, outside the loop's credits and steering.

Mock script (by request ordinal):
  1  "/loop wait for the build" -> one shell call with run_in_background.
     The turn yields; the job (a short sleep) is still running, so the run
     must HOLD instead of stopping.
  2  the job's completion wake -> a final message with no tool call. It must
     arrive as a /loop continuation: the wake text plus the continuation
     steering and pacing note. With the job gone, the run then stops idle.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

from codex_ws_mock import CodexMock, RecordedRequest, turn_events
from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def events(request: RecordedRequest) -> list[dict]:
    if request.ordinal == 1:
        return [
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "id": "fc_hold_1",
                    "call_id": "call_hold_1",
                    "name": "shell",
                    "arguments": json.dumps({"action": "run", "command": "sleep 2; echo HOLD_BUILD_DONE", "run_in_background": True}),
                    "status": "completed",
                },
            },
            turn_events("resp_hold_tool")[1],
        ]
    done = turn_events(f"resp_hold_{request.ordinal}")
    done[0]["item"]["content"][0]["text"] = f"HOLD_TURN_{request.ordinal}_DONE"
    return done


def main() -> None:
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-loop-hold-") as tmp:
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
                json.dump({"tokens": {"access_token": "loop-hold-mock", "account_id": "acct-loop-hold"}}, fh)
            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
                # Title/recap calls would shift the scripted request ordinals.
                json.dump({"ai_title": False, "session_recap": False, "skills": {"codedbpro": False}}, fh)
            env = {
                "HOME": tmp,
                "CODEX_HOME": codex_home,
                "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                "GRAFF_CODEX_WS": "off",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
            }
            ambient = tuple(
                name
                for name in os.environ
                if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR")
                and name not in env
            )
            with PtySession(
                GRAFF,
                ["--model", "codex", "--no-telemetry", "--yolo"],
                cwd=tmp,
                env=env,
                unset_env=ambient,
                timeout=15.0,
            ) as session:
                session.wait_for_prompt()
                cursor = len(session.raw)
                session.send_line("/loop wait for the build")
                session.wait_for_literal("run waiting", start=cursor, timeout=15.0)
                # The job's wake continues the run; with the job gone it stops idle.
                session.wait_for_literal("run stopped — idle", start=cursor, timeout=20.0)
                session.wait_for_prompt(start=cursor)
                session.send_key("ctrl-d")
                result = session.read_until_exit(5.0)
                if result.timed_out or result.exit_code != 0:
                    raise AssertionError(f"session did not exit cleanly: exit={result.exit_code} timed_out={result.timed_out}")
    finally:
        mock.stop()

    requests = mock.recorded_requests()
    if len(requests) != 2:
        raise AssertionError(f"expected exactly 2 model requests, got {len(requests)}")
    wake_turn = json.dumps(requests[1].body)
    for needle in ("HOLD_BUILD_DONE", "continuing autonomously (/loop)", "[pace: continuation"):
        if needle not in wake_turn:
            raise AssertionError(f"the wake turn did not continue the /loop run ({needle!r} missing): {wake_turn[-600:]!r}")
    print("ok    /loop holds for its background job, and the job's wake continues the run with its steering")


if __name__ == "__main__":
    main()
