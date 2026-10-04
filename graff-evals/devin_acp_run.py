#!/usr/bin/env python3
"""Eval arm: one prompt to Devin over ACP, as Harness drives it.

usage: devin_acp_run.py <model> <prompt>        (cwd = the task sandbox)

Spawns `devin ... acp`, opens a session in the cwd, sends the prompt,
auto-approves tool permissions, prints the answer to stdout and graff's
`[usage]` footer to stderr so run.py's graff-stderr parser scores it like
the other arms. DEVIN_ACP_DEBUG=1 also dumps the raw prompt response.
"""
import json, os, subprocess, sys, threading, time

# Devin list prices per 1M tokens, from `devin models list` (2026-10-04).
PRICES = {"gpt-6-1-sol": (2.0, 0.1, 10.0), "gpt-6-sol": (2.0, 0.2, 10.0)}


def price_for(model):
    for prefix, p in PRICES.items():
        if model.startswith(prefix):
            return p
    return None


def main():
    model, prompt = sys.argv[1], sys.argv[2]
    cwd = os.getcwd()
    devin = os.environ.get("DEVIN_BIN", os.path.expanduser("~/.local/bin/devin"))
    cmd = [devin, "--model", model, "--permission-mode", "dangerous", "--respect-workspace-trust=false", "acp"]
    proc = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, bufsize=1)
    pending, lock = {}, threading.Lock()
    answer, tool_calls, next_id = [], [0], [0]
    calls, last_key = [], [None]  # per-model-call usage from usage_update._meta

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def request(method, params):
        with lock:
            next_id[0] += 1
            rid = next_id[0]
            ev = threading.Event()
            pending[rid] = {"ev": ev, "res": None}
        send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return rid, ev

    def reader():
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if "id" in msg and ("result" in msg or "error" in msg) and "method" not in msg:
                slot = pending.get(msg["id"])
                if slot:
                    slot["res"] = msg
                    slot["ev"].set()
            elif msg.get("method") == "session/request_permission":
                opts = (msg.get("params") or {}).get("options") or []
                pick = next((o for o in opts if o.get("kind") == "allow_always"), None) or \
                       next((o for o in opts if str(o.get("kind", "")).startswith("allow")), None) or (opts[0] if opts else None)
                outcome = {"outcome": "selected", "optionId": pick["optionId"]} if pick else {"outcome": "cancelled"}
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"outcome": outcome}})
            elif msg.get("method") == "session/update":
                upd = (msg.get("params") or {}).get("update") or {}
                kind = upd.get("sessionUpdate")
                if kind == "agent_message_chunk":
                    content = upd.get("content") or {}
                    if content.get("type") == "text":
                        answer.append(content.get("text", ""))
                elif kind == "tool_call":
                    tool_calls[0] += 1
                elif kind == "usage_update":
                    meta = upd.get("_meta") or {}
                    key = tuple(int(meta.get(f"cognition.ai/{k}", 0) or 0) for k in
                                ("inputTokens", "outputTokens", "cachedReadTokens", "cachedWriteTokens"))
                    sub = meta.get("cognition.ai/subagent_context") or {}
                    # Devin echoes each root call once more tagged parentAgentId=root.
                    if not (sub.get("parentAgentId") == "root" and key == last_key[0]) and any(key):
                        calls.append(key)
                    last_key[0] = key
                if os.environ.get("DEVIN_ACP_DEBUG") and kind not in ("agent_message_chunk", "agent_thought_chunk"):
                    print(f"[devin-acp] update {kind}: {json.dumps(upd)[:300]}", file=sys.stderr)
            elif "id" in msg and "method" in msg:
                # Any other client request (fs/terminal): we advertised none.
                send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "not supported"}})

    threading.Thread(target=reader, daemon=True).start()
    t0 = time.monotonic()
    rid, ev = request("initialize", {"protocolVersion": 1, "clientCapabilities": {
        "fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}})
    ev.wait(60)
    rid, ev = request("session/new", {"cwd": cwd, "mcpServers": []})
    ev.wait(120)
    res = pending[rid]["res"] or {}
    sid = (res.get("result") or {}).get("sessionId")
    if not sid:
        print(f"[devin-acp] session/new failed: {json.dumps(res)[:400]}", file=sys.stderr)
        proc.kill()
        sys.exit(2)
    rid, ev = request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": prompt}]})
    ev.wait(float(os.environ.get("DEVIN_ACP_TIMEOUT", "1500")))
    res = pending[rid]["res"] or {}
    result = res.get("result") or {}
    if os.environ.get("DEVIN_ACP_DEBUG"):
        print(f"[devin-acp] prompt response: {json.dumps(res)[:2000]}", file=sys.stderr)
    proc.stdin.close()
    try:
        proc.wait(10)
    except subprocess.TimeoutExpired:
        proc.kill()

    text = "".join(answer).strip()
    print(text)
    usage = bool(calls)
    inp, out, cached, writes = (sum(c[i] for c in calls) for i in range(4))
    price = price_for(model)
    tail = ""
    if usage and price:
        uncached = max(inp - cached, 0)
        cost = (uncached * price[0] + cached * price[1] + out * price[2]) / 1e6
        tail = f" · ${cost:.8f}"
    elif not usage:
        tail = " · totals incomplete: 1 call(s) missing usage (tokens and cost unknown)"
    print(f"[usage] {len(calls)} api call(s) · {inp} in ({cached} cached, {writes} cache writes) + {out} out tokens{tail}",
          file=sys.stderr)
    print(f"[devin-acp] stop={result.get('stopReason')} tools={tool_calls[0]} wall={time.monotonic() - t0:.1f}s",
          file=sys.stderr)


if __name__ == "__main__":
    main()
