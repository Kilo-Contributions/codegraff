#!/usr/bin/env python3
"""Offline (ADR 0233): a scripted `graff repl` runs a two-second command that
the model sent with `timeout: 1000`, then writes a todo list.

- The command finishes in the foreground: a model's one-second wait is raised
  to the 5s floor instead of parking the command after one second.
- todo_write answers with counts, not the list the model just sent.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts/eval"))
from mock_model import ScriptedModel

PROMPT = "Run the slow check, then plan the follow-up."
MARKER = "slow-check-finished"
TODOS = [
    {"content": "inspect the slow check output", "status": "completed"},
    {"content": "write the follow-up fix", "status": "in_progress"},
    {"content": "verify the follow-up fix", "status": "pending"},
]


class Model(ScriptedModel):
    def __init__(self):
        super().__init__([], exhausted_text="All done.")
        self.root_bodies = []

    def next_reply(self, body):
        with self._lock:
            self.requests.append(body)
            if PROMPT in json.dumps(body.get("messages", [])) and body.get("tools"):
                self.root_bodies.append(body)
            n = len(self.root_bodies)
        if not body.get("tools"):
            return {"text": "Short title"}
        if n == 1:
            return {"tool": "shell", "arguments": {"command": f"sleep 2; echo {MARKER}", "timeout": 1000}}
        if n == 2:
            return {"tool": "todo_write", "arguments": {"todos": TODOS}}
        return {"text": "All done."}


def tool_results(body):
    return [m.get("content") for m in body.get("messages", []) if m.get("role") == "tool"]


def main():
    binary = (Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve()
    model = Model()
    port = model.start(0)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            work = Path(tmp) / "work"
            home.mkdir()
            work.mkdir()
            env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY") and not k.startswith(("GRAFF_", "HARNESS_"))}
            env.update(HOME=str(home), AI_GATEWAY_API_KEY="local", GRAFF_FLEET="off",
                       GRAFF_VERCEL_URL=f"http://127.0.0.1:{port}/v1/chat/completions",
                       GRAFF_NO_TELEMETRY="1", GRAFF_NO_SMOLIFY="1", GRAFF_BEHAVIOR_UPLOAD="off", NO_COLOR="1")
            proc = subprocess.run([str(binary), "repl", "--yolo", "--old", "--model", "vercel"],
                                  input=PROMPT + "\n", text=True, encoding="utf-8", errors="replace", capture_output=True,
                                  cwd=work, env=env, timeout=120)
    finally:
        model.stop()
    tail = f"\nstdout:\n{proc.stdout[-1500:]}\nstderr:\n{proc.stderr[-1500:]}"
    assert len(model.root_bodies) >= 3, f"expected three root requests, got {len(model.root_bodies)}{tail}"
    shell_out = tool_results(model.root_bodies[1])[-1]
    assert MARKER in shell_out, f"the two-second command did not finish in the foreground: {shell_out!r}{tail}"
    assert "foreground wait" not in shell_out, f"the command was parked: {shell_out!r}"
    todo_out = tool_results(model.root_bodies[2])[-1]
    assert todo_out.startswith("Todo list saved: 1 done, 1 in progress, 1 pending."), f"todo_write reply: {todo_out!r}"
    assert not any(t["content"] in todo_out for t in TODOS), f"todo_write echoed the list back: {todo_out!r}"
    print("PASS a model's 1s shell wait is raised to the floor; todo_write replies with counts (ADR 0233)")


if __name__ == "__main__":
    main()
