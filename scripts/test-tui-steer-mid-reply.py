#!/usr/bin/env python3
"""Live proof that a follow-up typed in the TUI while the reply streams joins
the running turn: the streaming reply is superseded and the request rebuilt.

Against the real binary under a pty, with a mock provider streaming slowly:

  1. boots `graff tui --yolo --model codex` pointed at scripts/codex_ws_mock,
  2. sends a prompt; the first reply streams a long story a word at a time,
  3. mid-stream, types a follow-up and presses Enter,
  4. asserts the second request carries the follow-up and none of the
     abandoned partial story, and that its reply reaches the screen.

Usage: python3 scripts/test-tui-steer-mid-reply.py [path/to/graff]
Exit 0 = pass. Skips (exit 0, notice) with no pty support.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import time

from codex_ws_mock import USAGE, CodexMock, RecordedRequest, turn_events

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
BOOT_MAX = 20.0
ROWS, COLS = 40, 110
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


def drain(fd, seconds):
    import select

    out = b""
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], min(0.1, max(end - time.time(), 0.01)))
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    return out


def resize(fd, rows, cols):
    import fcntl
    import struct
    import termios

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def boot(fd):
    out = b""
    end = time.time() + BOOT_MAX
    while time.time() < end:
        out += drain(fd, 0.3)
        if b"\x1b[?1049h" in out:
            return out + drain(fd, 1.5)
    return out


def wait_for(fd, needle, seconds):
    out = b""
    end = time.time() + seconds
    while time.time() < end:
        out += drain(fd, 0.3)
        if needle.encode() in out:
            return out
    return None


def spawn(cwd, env_extra, unset):
    import pty

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        for name in unset:
            os.environ.pop(name, None)
        os.environ.update(env_extra)
        os.execv(BIN, [BIN, "tui", "--yolo", "--model", "codex", "--no-telemetry"])
    resize(fd, ROWS, COLS)
    return pid, fd


def reap(pid, fd):
    import signal

    try:
        os.write(fd, b"\x11")  # Ctrl+Q
        drain(fd, 2.0)
    except OSError:
        pass
    for call in (lambda: os.kill(pid, signal.SIGKILL), lambda: os.waitpid(pid, 0)):
        try:
            call()
        except OSError:
            pass


def full_frame(fd):
    """Screen rows, in order, from a FORCED full repaint (see #529's probe)."""
    resize(fd, ROWS - 1, COLS)
    drain(fd, 0.4)
    resize(fd, ROWS, COLS)
    stream = drain(fd, 1.5)
    frame = stream.rsplit(b"\x1b[2J\x1b[H", 1)
    if len(frame) < 2:
        return None
    text = re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", frame[1])
    text = re.sub(rb"\x1b\[[0-9;?<>]*[a-zA-Z]", b"", text)
    return [ln.decode(errors="replace") for ln in text.split(b"\r\n")]


def workspace(tmp, port):
    codex_home = os.path.join(tmp, "codex-home")
    os.makedirs(codex_home)
    with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
        json.dump({"tokens": {"access_token": "steer-mock", "account_id": "acct-steer"}}, fh)
    harness = os.path.join(tmp, ".harness")
    os.makedirs(harness)
    with open(os.path.join(harness, "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"ai_title": False, "session_recap": False, "skills": {"codedbpro": False}}, fh)
    empty_mcp = os.path.join(tmp, "empty-mcp.json")
    with open(empty_mcp, "w", encoding="utf-8") as fh:
        fh.write('{"mcpServers": {}}')
    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
        "GRAFF_CODEX_WS": "off",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_MCP_CONFIG": empty_mcp,
        "GRAFF_LEARN_AUTO": "off",
    }
    unset = tuple(
        name
        for name in os.environ
        if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR")
        and name not in env
    )
    return env, unset



def run():
    mock = CodexMock(events_for_request=events, delay_for_request=lambda r: 0.12 if r.ordinal == 1 else 0.0)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-tui-steer-") as tmp:
            env, unset = workspace(tmp, port)
            pid, fd = spawn(tmp, env, unset)
            try:
                boot(fd)
                os.write(fd, b"tell me a story\r")
                if wait_for(fd, "PARTIAL_STORY_03", 20.0) is None:
                    return "the first reply never started streaming"
                for ch in FOLLOW_UP:
                    os.write(fd, ch.encode())
                    time.sleep(0.01)
                os.write(fd, b"\r")
                if wait_for(fd, "STEERED_REPLY_DONE", 30.0) is None:
                    return "the rebuilt reply never reached the screen"
            finally:
                reap(pid, fd)
        requests = mock.recorded_requests()
        if len(requests) != 2:
            return f"expected the story request and one rebuilt request, got {len(requests)}"
        rebuilt = json.dumps(requests[1].body)
        if FOLLOW_UP not in rebuilt:
            return "the rebuilt request did not carry the follow-up"
        if "PARTIAL_STORY_" in rebuilt:
            return "the abandoned partial story leaked into the rebuilt request"
        return None
    finally:
        mock.stop()


def main():
    if not os.path.exists(BIN):
        print(f"tui-steer: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-steer: no pty support here — skipping")
        return 0
    err = run()
    if err:
        print(f"  ✗ tui steer: {err}")
        return 1
    print("  ✓ tui steer: a follow-up typed mid-stream joins the turn and rebuilds the reply")
    return 0


if __name__ == "__main__":
    sys.exit(main())
