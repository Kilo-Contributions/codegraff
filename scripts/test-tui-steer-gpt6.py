#!/usr/bin/env python3
"""GPT-6 mid-turn steering end to end: the real binary under a pty, a mock
Codex socket playing the server's side of `response.steer`.

  1. continuation: a follow-up typed while the reply streams goes out as a
     steer; the server accepts it, ends the reply `incomplete: steered` and
     streams a continuation. No rebuilt request, and the next turn's full
     input carries the steer once, between the cut reply and the
     continuation (the TUI re-anchors every turn on a fresh socket).
  2. pending: a steer that meets a client tool call waits for the tool output.
     The tool loop runs at once (no wait for a continuation that never
     comes), and the output request does not repeat the steer.
  3. failed: a rejected steer is not lost; it runs as the next message.

Usage: python3 scripts/test-tui-steer-gpt6.py [path/to/graff]
Exit 0 = pass. Skips (exit 0, notice) with no pty support.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time

from codex_ws_mock import USAGE, CodexMock, RecordedRequest

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
BOOT_MAX = 20.0
ROWS, COLS = 40, 110
WORDS = [f"STORY_{i:02d} " for i in range(60)]
FOLLOW_UP = "also mention the tests"


def created(rid: str) -> dict:
    return {"type": "response.created", "response": {"id": rid, "status": "in_progress"}}


def delta(text: str) -> dict:
    return {"type": "response.output_text.delta", "item_id": "msg", "output_index": 0, "content_index": 0, "delta": text}


def message(text: str) -> dict:
    return {"type": "response.output_item.done", "item": {
        "type": "message", "id": "msg", "status": "completed", "role": "assistant",
        "content": [{"type": "output_text", "text": text, "annotations": []}]}}


def ended(rid: str, reason: str | None = None) -> dict:
    response = {"id": rid, "status": "incomplete" if reason else "completed", "usage": dict(USAGE)}
    if reason:
        response["incomplete_details"] = {"reason": reason}
    return {"type": "response.incomplete" if reason else "response.completed", "response": response}


def reply(rid: str, text: str) -> list[dict]:
    return [created(rid), delta(text), message(text), ended(rid)]


def story(rid: str) -> list[dict]:
    return [created(rid)] + [delta(w) for w in WORDS] + [message("".join(WORDS)), ended(rid)]


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


def type_line(fd, text):
    # Keep reading while typing: a TUI whose pty output nobody drains blocks
    # on its next write and never sees the keys.
    for ch in text:
        os.write(fd, ch.encode())
        drain(fd, 0.01)
    drain(fd, 0.4)  # past the composer's paste-burst window, so Enter sends
    os.write(fd, b"\r")


def spawn(cwd, env_extra, unset):
    import pty

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        for name in unset:
            os.environ.pop(name, None)
        os.environ.update(env_extra)
        os.execv(BIN, [BIN, "tui", "--yolo", "--model", "codex/gpt-6-sol", "--no-telemetry"])
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


def session(mock: CodexMock, flow) -> str | None:
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-tui-steer6-") as tmp:
            env, unset = workspace(tmp, port)
            pid, fd = spawn(tmp, env, unset)
            try:
                boot(fd)
                return flow(fd)
            finally:
                reap(pid, fd)
    finally:
        mock.stop()


def user_texts(body: dict) -> list[str]:
    """Every user message in a request's input (either content shape)."""
    out = []
    for item in body.get("input") or []:
        if not isinstance(item, dict) or item.get("role") != "user":
            continue
        content = item.get("content")
        if isinstance(content, str):
            out.append(content)
        elif isinstance(content, list):
            out.extend(part.get("text", "") for part in content if isinstance(part, dict))
    return out


def continuation() -> str | None:
    def events(r: RecordedRequest) -> list[dict]:
        return story("resp_story") if r.ordinal == 1 else reply(f"resp_after_{r.ordinal}", "SECOND_REPLY_OK")

    def on_steer(_r, steer, remaining):
        cut = [e for e in remaining if e["type"] != "response.output_text.delta"][:1]  # the reply's item, finished
        return [{"type": "response.steer.accepted", "steer": {"id": "steer_1", "previous_response_id": steer["previous_response_id"]}}], (
            cut + [ended("resp_story", "steered")] + reply("resp_cont", "CONTINUATION_OK"))

    mock = CodexMock(events_for_request=events, on_steer=on_steer, delay_for_request=lambda r: 0.12 if r.ordinal == 1 else 0.0)

    def flow(fd):
        type_line(fd, "tell me a story")
        if wait_for(fd, "STORY_03", 20.0) is None:
            return "the first reply never started streaming"
        type_line(fd, FOLLOW_UP)
        if wait_for(fd, "CONTINUATION_OK", 30.0) is None:
            return "the continuation never reached the screen"
        type_line(fd, "what next")
        if wait_for(fd, "SECOND_REPLY_OK", 20.0) is None:
            return "the next turn never finished"
        return None

    err = session(mock, flow)
    if err:
        return err
    if len(mock.steers) != 1 or mock.steers[0].get("previous_response_id") != "resp_story" or mock.steers[0].get("input") != FOLLOW_UP:
        return f"expected one steer on resp_story carrying the follow-up, got {mock.steers}"
    requests = mock.recorded_requests()
    if len(requests) != 2:
        return f"expected the story and the next turn (no rebuilt reply), got {len(requests)} requests"
    full = requests[1].body
    texts = user_texts(full)
    if texts.count(FOLLOW_UP) != 1:
        return f"the next turn's input carried the steer {texts.count(FOLLOW_UP)} times: {texts}"
    items = json.dumps(full.get("input"))
    at_story, at_steer, at_cont = items.find("STORY_00"), items.find(FOLLOW_UP), items.find("CONTINUATION_OK")
    if not (0 <= at_story < at_steer < at_cont):
        return "history does not hold the steer between the cut reply and the continuation"
    return None


def pending() -> str | None:
    steer_text = "keep it to one line"
    thinking = [{"type": "response.reasoning_summary_text.delta", "item_id": "rs", "output_index": 0, "summary_index": 0, "delta": "thinking "}] * 25
    call = {"type": "response.output_item.done", "item": {
        "type": "function_call", "id": "fc_1", "call_id": "call_todo", "name": "todo_read", "arguments": "{}", "status": "completed"}}

    def events(r: RecordedRequest) -> list[dict]:
        if r.ordinal == 1:
            return [created("resp_tool")] + thinking + [call, ended("resp_tool")]
        return reply(f"resp_after_{r.ordinal}", "PENDING_APPLIED_OK")

    def on_steer(_r, steer, remaining):
        held = {"type": "response.steer.pending", "steer": {"id": "steer_1", "previous_response_id": steer["previous_response_id"]},
                "reason": "waiting_for_required_input",
                "required_input": [{"type": "function_call_output", "call_id": "call_todo", "name": "todo_read"}]}
        return [{"type": "response.steer.accepted", "steer": {"id": "steer_1", "previous_response_id": steer["previous_response_id"]}}], remaining + [held]

    mock = CodexMock(events_for_request=events, on_steer=on_steer, delay_for_request=lambda r: 0.15 if r.ordinal == 1 else 0.0)
    timing = {}

    def flow(fd):
        type_line(fd, "draft a short plan")
        drain(fd, 1.2)  # the reply is thinking
        type_line(fd, steer_text)
        timing["steered"] = time.time()
        if wait_for(fd, "PENDING_APPLIED_OK", 40.0) is None:
            return "the tool output request never finished"
        timing["done"] = time.time()
        return None

    err = session(mock, flow)
    if err:
        return err
    if len(mock.steers) != 1:
        return f"expected one steer, got {len(mock.steers)}"
    requests = mock.recorded_requests()
    if len(requests) != 2:
        return f"expected the tool call and its output request, got {len(requests)} requests"
    out = requests[1].body
    if out.get("previous_response_id") != "resp_tool":
        return f"the tool output chained on {out.get('previous_response_id')!r}, not the steered response"
    if "call_todo" not in json.dumps(out.get("input")):
        return "the output request did not carry the tool output"
    if steer_text in json.dumps(out.get("input")):
        return "the output request repeated a steer the server prepends itself"
    if timing["done"] - timing["steered"] > 20:
        return f"the tool loop waited {timing['done'] - timing['steered']:.0f}s for a continuation that never comes"
    return None


def failed() -> str | None:
    def events(r: RecordedRequest) -> list[dict]:
        return story("resp_story") if r.ordinal == 1 else reply(f"resp_next_{r.ordinal}", "REQUEUED_OK")

    def on_steer(_r, steer, remaining):
        return [{"type": "response.steer.failed", "steer": {"previous_response_id": steer["previous_response_id"]},
                 "error": {"code": "invalid_input", "type": "invalid_request_error", "message": "mock rejection"}}], remaining

    mock = CodexMock(events_for_request=events, on_steer=on_steer, delay_for_request=lambda r: 0.12 if r.ordinal == 1 else 0.0)

    def flow(fd):
        type_line(fd, "tell me a story")
        if wait_for(fd, "STORY_03", 20.0) is None:
            return "the first reply never started streaming"
        type_line(fd, FOLLOW_UP)
        if wait_for(fd, "REQUEUED_OK", 40.0) is None:
            return "the rejected follow-up never ran"
        return None

    err = session(mock, flow)
    if err:
        return err
    requests = mock.recorded_requests()
    if len(requests) != 2:
        return f"expected the story and the follow-up's own request, got {len(requests)}"
    if user_texts(requests[1].body).count(FOLLOW_UP) != 1:
        return "the follow-up request did not carry the rejected steer exactly once"
    return None


def main():
    if not os.path.exists(BIN):
        print(f"tui-steer-gpt6: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-steer-gpt6: no pty support here — skipping")
        return 0
    failures = 0
    for name, case in (("continuation", continuation), ("pending", pending), ("failed", failed)):
        err = case()
        if err:
            failures += 1
            print(f"  ✗ gpt-6 steer {name}: {err}")
        else:
            print(f"  ✓ gpt-6 steer {name}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
