#!/usr/bin/env python3
"""Drive `codex app-server` (JSON-RPC over stdio) for one graff-evals task.

usage: codex_app_server.py <model> <prompt>            (cwd = the task sandbox)
       codex_app_server.py --probe <model>             (model list + rate limits)

Codex runs from a throwaway CODEX_HOME outside the sandbox: an access-only
copy of the ChatGPT login (no refresh token, so an eval can never rotate the
real one), a config.toml with the model and effort, and the sandbox's
`.mcp.json` servers registered as codex `mcp_servers`. Project docs are off
(`project_doc_max_bytes = 0`), as graff sees none in an isolated sandbox.

The final agent message goes to stdout (the runner's `answer: stdout`). Token
usage from `thread/tokenUsage/updated` goes to stderr as graff's `[usage]`
footer, so the runner's graff-stderr parser scores both harnesses alike.

Steering (graff-evals steering scenarios): EVAL_STEER=<text> sends
`turn/steer` once the first agent text or reasoning arrives
(EVAL_STEER_AFTER=text|start); EVAL_FOLLOWUP=<text> runs one more turn after
the first completes. Neither is set for ordinary tasks.
"""
from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone


def codex_home(model: str, sandbox: str) -> str:
    home = tempfile.mkdtemp(prefix="eval-codex-home-")
    source = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    real = json.load(open(os.path.join(source, "auth.json")))
    tokens = real.get("tokens") or {}
    access_only = {
        "OPENAI_API_KEY": None,
        "tokens": {
            "id_token": tokens.get("id_token"),
            "access_token": tokens.get("access_token"),
            "refresh_token": "",
            "account_id": tokens.get("account_id"),
        },
        "last_refresh": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
    }
    with open(os.path.join(home, "auth.json"), "w") as fh:
        json.dump(access_only, fh)
    os.chmod(os.path.join(home, "auth.json"), 0o600)
    lines = [
        f'model = "{model}"',
        f'model_reasoning_effort = "{os.environ.get("EVAL_EFFORT", "medium")}"',
        'approval_policy = "never"',
        'sandbox_mode = "danger-full-access"',
        "project_doc_max_bytes = 0",
        "check_for_update_on_startup = false",
    ]
    mcp = os.path.join(sandbox, ".mcp.json")
    if os.path.exists(mcp):
        servers = (json.load(open(mcp)).get("mcpServers") or {})
        for name, spec in servers.items():
            args = [a if os.path.isabs(a) or not os.path.exists(os.path.join(sandbox, a)) else os.path.join(sandbox, a)
                    for a in spec.get("args", [])]
            lines += ["", f"[mcp_servers.{name}]", f"command = {json.dumps(spec['command'])}", f"args = {json.dumps(args)}"]
            if spec.get("env"):
                lines.append("env = { " + ", ".join(f"{k} = {json.dumps(v)}" for k, v in spec["env"].items()) + " }")
    with open(os.path.join(home, "config.toml"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return home


class AppServer:
    def __init__(self, home: str, cwd: str):
        env = dict(os.environ, CODEX_HOME=home)
        env.pop("OPENAI_API_KEY", None)
        self.p = subprocess.Popen(["codex", "app-server"], cwd=cwd, env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.inbox: queue.Queue = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.inbox.put(json.loads(line))
            except ValueError:
                pass
        self.inbox.put(None)

    def send(self, obj: dict):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def request(self, method: str, params: dict | None, on_event=None, timeout: float = 60.0):
        self.next_id += 1
        rid = self.next_id
        self.send({"id": rid, "method": method, "params": params or {}})
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            msg = self.next(end - time.monotonic())
            if msg is None:
                break
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                if "error" in msg:
                    raise RuntimeError(f"{method}: {json.dumps(msg['error'])[:300]}")
                return msg["result"]
            if on_event:
                on_event(msg)
        raise TimeoutError(method)

    def next(self, timeout: float):
        try:
            return self.inbox.get(timeout=max(timeout, 0.01))
        except queue.Empty:
            return None

    def answer_server_request(self, msg: dict) -> bool:
        """Approvals should never come with approval_policy=never; accept if they do."""
        if "id" in msg and "method" in msg and "result" not in msg:
            self.send({"id": msg["id"], "result": {"decision": "accept"}})
            return True
        return False

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


def text_input(text: str) -> list[dict]:
    return [{"type": "text", "text": text, "text_elements": []}]


def run_turn(srv: AppServer, thread_id: str, text: str, deadline: float, steer: str = "", steer_after: str = "text"):
    """One turn; returns (final agent text, turn status, steer outcome)."""
    state = {"turn": None, "done": None, "answer": "", "steered": "", "usage": None, "armed": 0.0, "t0": time.monotonic()}
    delay = float(os.environ.get("EVAL_STEER_DELAY_S", "0"))

    def on_event(msg):
        if srv.answer_server_request(msg):
            return
        method = msg.get("method")
        params = msg.get("params") or {}
        if method == "turn/started":
            state["turn"] = (params.get("turn") or {}).get("id") or state["turn"]
        elif method == "item/started" and (params.get("item") or {}).get("type") == "agentMessage" and state.get("steer_at") and not state.get("after_item"):
            state["after_item"] = time.monotonic()
        elif method == "item/completed":
            item = params.get("item") or {}
            if item.get("type") == "agentMessage":
                state["answer"] = item.get("text") or state["answer"]
        elif method == "thread/tokenUsage/updated":
            state["usage"] = (params.get("tokenUsage") or {}).get("total")
            state["calls"] = state.get("calls", 0) + 1
            if os.environ.get("EVAL_DEBUG"):
                print(f"[usage-event] {json.dumps(params.get('tokenUsage'))}", file=sys.stderr)
        elif method == "turn/completed":
            state["done"] = params.get("turn") or {}
        if steer and not state["steered"] and state["turn"]:
            trigger = method in ("item/agentMessage/delta", "item/reasoning/summaryTextDelta") if steer_after == "text" else method == "turn/started"
            if trigger and not state["armed"]:
                state["armed"] = time.monotonic()
            if state["armed"] and time.monotonic() - state["armed"] >= delay:
                state["steered"] = "sent"
                state["steer_at"] = time.monotonic()
                try:
                    srv.request("turn/steer", {"threadId": thread_id, "input": text_input(steer), "expectedTurnId": state["turn"]},
                                on_event=on_event, timeout=30)
                    state["steered"] = "accepted"
                except Exception as e:  # noqa: BLE001
                    state["steered"] = f"refused: {e}"[:200]

    result = srv.request("turn/start", {"threadId": thread_id, "input": text_input(text)}, on_event=on_event, timeout=60)
    state["turn"] = state["turn"] or (result.get("turn") or {}).get("id")
    while state["done"] is None and time.monotonic() < deadline:
        msg = srv.next(deadline - time.monotonic())
        if msg is None:
            break
        on_event(msg)
    status = (state["done"] or {}).get("status", "timeout")
    if state.get("steer_at"):
        after = state.get("after_item")
        print(f"[codex-app-server] steer at {state['steer_at'] - state['t0']:.1f}s; next agent message "
              f"{'+' + format(after - state['steer_at'], '.1f') + 's' if after else 'never'}; turn done "
              f"+{time.monotonic() - state['steer_at']:.1f}s", file=sys.stderr)
    if os.environ.get("EVAL_PRINT_TURNS"):
        print(f"--- turn answer ---\n{state['answer']}", file=sys.stderr)
    return state["answer"], status, state["steered"], state["usage"], state.get("calls", 0)


def footer(usage: dict | None, calls: int) -> str:
    """graff's `[usage]` shape; codex's inputTokens, like graff's `in`, includes cached reads."""
    u = usage or {}
    return (f"[usage] {calls} api call(s) · {u.get('inputTokens', 0)} in ({u.get('cachedInputTokens', 0)} cached, "
            f"{u.get('cacheWriteInputTokens', 0)} cache writes) + {u.get('outputTokens', 0)} out tokens")


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--probe":
        model, sandbox = sys.argv[2], os.getcwd()
        home = codex_home(model, sandbox)
        srv = AppServer(home, sandbox)
        try:
            srv.request("initialize", {"clientInfo": {"name": "graff-evals", "title": "graff-evals", "version": "0.1"}, "capabilities": None})
            srv.send({"method": "initialized"})
            models = srv.request("model/list", {})
            names = [m.get("model") or m.get("id") for m in (models.get("data") or models.get("models") or [])]
            print("models:", [n for n in names if n and ("gpt-6" in n or "gpt-5.6" in n)])
            limits = srv.request("account/rateLimits/read", {})
            print("rate limits:", json.dumps(limits)[:600])
        finally:
            srv.close()
            shutil.rmtree(home, ignore_errors=True)
        return 0
    model, prompt = sys.argv[1], sys.argv[2]
    sandbox = os.getcwd()
    deadline = time.monotonic() + float(os.environ.get("EVAL_TIMEOUT_S", "900"))
    home = codex_home(model, sandbox)
    srv = AppServer(home, sandbox)
    try:
        srv.request("initialize", {"clientInfo": {"name": "graff-evals", "title": "graff-evals", "version": "0.1"}, "capabilities": None})
        srv.send({"method": "initialized"})
        thread = srv.request("thread/start", {"model": model, "cwd": sandbox, "approvalPolicy": "never",
                                              "sandbox": "danger-full-access", "ephemeral": True}, timeout=60)
        thread_id = (thread.get("thread") or {}).get("id")
        answer, status, steered, usage, calls = run_turn(srv, thread_id, prompt, deadline, os.environ.get("EVAL_STEER", ""),
                                                         os.environ.get("EVAL_STEER_AFTER", "text"))
        turns = 1
        if os.environ.get("EVAL_FOLLOWUP") and status == "completed":
            answer, status, _, usage2, calls2 = run_turn(srv, thread_id, os.environ["EVAL_FOLLOWUP"], deadline)
            usage, calls, turns = usage2 or usage, calls + calls2, 2
        print(answer)
        print(f"[codex-app-server] status={status} steer={steered or '-'} turns={turns}", file=sys.stderr)
        print(footer(usage, calls), file=sys.stderr)
        return 0 if status == "completed" else 1
    finally:
        srv.close()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
