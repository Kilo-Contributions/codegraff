#!/usr/bin/env python3
"""Real-PTY regression: a follow-up typed while the reply streams supersedes it.

Mock script (by request ordinal):
  1  "tell me a story" -> a long reply streamed slowly. Mid-stream the user
     types a follow-up and presses Enter. The stream must be cut there.
  2  the rebuilt request -> a short reply. It must carry the follow-up and
     none of the abandoned partial reply, which never entered history.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

from codex_ws_mock import USAGE, CodexMock, RecordedRequest, turn_events
from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg

WORDS = [f"PARTIAL_STORY_{i:02d} " for i in range(60)]
FOLLOW_UP = "also mention the tests"


def story_events() -> list[dict]:
    events: list[dict] = [
        {"type": "response.output_text.delta", "item_id": "msg_story", "output_index": 0, "content_index": 0, "delta": w}
        for w in WORDS
    ]
    events.append({
        "type": "response.output_item.done",
        "item": {
            "type": "message",
            "id": "msg_story",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": "".join(WORDS), "annotations": []}],
        },
    })
    events.append({"type": "response.completed", "response": {"id": "resp_story", "usage": dict(USAGE)}})
    return events


def events(request: RecordedRequest) -> list[dict]:
    if request.ordinal == 1:
        return story_events()
    done = turn_events(f"resp_steer_{request.ordinal}")
    done[0]["item"]["content"][0]["text"] = "STEERED_REPLY_DONE"
    return done


def run_case(label: str, env_extra: dict[str, str], model: str) -> None:
    mock = CodexMock(
        events_for_request=events,
        delay_for_request=lambda r: 0.12 if r.ordinal == 1 else 0.0,
    )
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-steer-") as tmp:
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
                json.dump({"tokens": {"access_token": "steer-mock", "account_id": "acct-steer"}}, fh)
            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
                # Title/recap calls would shift the scripted request ordinals.
                json.dump({"ai_title": False, "session_recap": False, "skills": {"codedbpro": False}}, fh)
            env = {
                "HOME": tmp,
                "CODEX_HOME": codex_home,
                "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
                **env_extra,
            }
            ambient = tuple(
                name
                for name in os.environ
                if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR")
                and name not in env
            )
            with PtySession(
                GRAFF,
                ["--model", model, "--no-telemetry", "--yolo"],
                cwd=tmp,
                env=env,
                unset_env=ambient,
                timeout=20.0,
            ) as session:
                session.wait_for_prompt()
                cursor = len(session.raw)
                session.send_line("tell me a story")
                session.wait_for_literal("PARTIAL_STORY_03", start=cursor, timeout=15.0)
                session.send_line(FOLLOW_UP)
                session.wait_for_literal("restarting the reply", start=cursor, timeout=15.0)
                session.wait_for_literal("STEERED_REPLY_DONE", start=cursor, timeout=15.0)
                session.wait_for_prompt(start=cursor)
                session.send_key("ctrl-d")
                result = session.read_until_exit(5.0)
                if result.timed_out or result.exit_code != 0:
                    raise AssertionError(f"{label}: session did not exit cleanly: exit={result.exit_code} timed_out={result.timed_out}")
    finally:
        mock.stop()

    turns = [r for r in mock.recorded_requests() if r.body.get("generate") is not False]
    if len(turns) != 2:
        raise AssertionError(f"{label}: expected exactly 2 model requests, got {len(turns)}")
    rebuilt = json.dumps(turns[1].body)
    if FOLLOW_UP not in rebuilt:
        raise AssertionError(f"{label}: the rebuilt request did not carry the follow-up: {rebuilt[-600:]!r}")
    if "PARTIAL_STORY_" in rebuilt:
        raise AssertionError(f"{label}: the abandoned partial reply leaked into the rebuilt request's history")
    print(f"ok    {label}: a follow-up typed mid-stream supersedes the reply and the request is rebuilt with it")


def main() -> None:
    run_case("sse", {"GRAFF_CODEX_WS": "off"}, "codex")
    # A model without server-side response.steer: the WebSocket reply is cut too.
    run_case("websocket", {}, "codex/gpt-5.6-sol")


if __name__ == "__main__":
    main()
