#!/usr/bin/env python3
"""Offline: a scripted `graff repl` waits for the background subagent its turn
started (ADR 0215). The child answers only after the root has ended its reply,
so its report can reach the root only through the idle wait; before the fix the
script hit EOF and graff exited with the child still running."""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts/eval"))
from mock_model import ScriptedModel

PROMPT = "Start the background child."
REPORT = "child report: the answer is 42"
DONE = "Done: the child says 42."


class Model(ScriptedModel):
    def __init__(self):
        super().__init__([], exhausted_text="unexpected model request")
        self.root_bodies = []
        self.root_ended = threading.Event()

    def next_reply(self, body):
        text = json.dumps(body.get("messages", []))
        with self._lock:
            self.requests.append(body)
            # A child's first message quotes the user's request too (ADR 0232); its own system prompt tells it apart.
            root = PROMPT in text and "You are a subagent" not in text
            if root:
                self.root_bodies.append(body)
            n = len(self.root_bodies)
        if not body.get("tools"):
            return {"text": "Short title"}
        if not root:
            assert self.root_ended.wait(30), "the root never ended its reply"
            time.sleep(0.5)
            return {"text": REPORT}
        if n == 1:
            return {"tool": "subagent", "arguments": {
                "description": "Background child", "prompt": "Report the answer.",
                "isolation": "shared_cwd", "run_in_background": True}}
        if n == 2:
            self.root_ended.set()
            return {"text": "Waiting for the child to report."}
        return {"text": DONE}


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
                                  cwd=work, env=env, timeout=90)
    finally:
        model.stop()
    tail = f"\nstdout:\n{proc.stdout[-1500:]}\nstderr:\n{proc.stderr[-1500:]}"
    assert len(model.root_bodies) >= 3, f"the root ended with its child still running ({len(model.root_bodies)} root requests){tail}"
    assert any(REPORT in json.dumps(b) for b in model.root_bodies[2:]), f"the child's report never reached the root{tail}"
    assert DONE in proc.stdout, f"the resumed turn's answer is missing{tail}"
    print("PASS scripted repl waits for the background subagent it started (ADR 0215)")


if __name__ == "__main__":
    main()
