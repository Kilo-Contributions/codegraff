#!/usr/bin/env python3
"""Run deepseek-harness (dsh) headless on one eval task and report like graff does.

usage: dsh_run.py [PROVIDER/]MODEL PROMPT     (cwd = the task sandbox)

dsh has no --model flag, so a patch layer pins `agent-default-model`
(provider defaults to deepseek-official). dsh does not read `.mcp.json`; each
server there becomes a `@deepseek-ai/dsh-mcp-client` entry in the same patch.
The final message goes to stdout; a graff-format `[usage]` line goes to
stderr, summed over the run's step_end events. stdin is empty.
"""
import json, os, subprocess, sys, tempfile

DSH = os.environ.get("DSH_BIN", "dsh")
model, prompt = sys.argv[1], sys.argv[2]
provider, _, name = model.rpartition("/")
cwd = os.getcwd()

patch = [{"id": "agent-default-model", "config": {"provider": provider or "deepseek-official", "model": name}}]
if os.path.exists(".mcp.json"):
    for server, spec in json.load(open(".mcp.json")).get("mcpServers", {}).items():
        args = [os.path.join(cwd, a) if os.path.exists(os.path.join(cwd, a)) else a for a in spec.get("args", [])]
        cfg = {"serverName": server, "transport": "stdio", "command": spec["command"], "args": args}
        if spec.get("env"):
            cfg["env"] = spec["env"]
        patch.append({"id": f"mcp-{server}", "name": "@deepseek-ai/dsh-mcp-client", "config": cfg})
fd, path = tempfile.mkstemp(prefix="dsh-patch-", suffix=".yml")
os.write(fd, json.dumps(patch).encode())  # JSON is valid YAML
os.close(fd)
try:
    r = subprocess.run([DSH, "--profile", "headless", "--patch", path, "--json", prompt],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True)
finally:
    os.unlink(path)

final, texts = None, []
calls = tin = tout = tread = twrite = 0
for line in r.stdout.splitlines():
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    kind = ev.get("type")
    if kind == "final":
        final = ev.get("text")
    elif kind == "text":
        texts.append(ev.get("text", ""))
    elif kind == "status" and ev.get("phase") == "step_end":
        u = ev.get("usage") or {}
        calls += 1
        tin += u.get("inputTokens") or 0
        tout += u.get("outputTokens") or 0
        tread += u.get("cacheReadTokens") or 0
        twrite += u.get("cacheWriteTokens") or 0
print(final if final is not None else (texts[-1] if texts else ""))
sys.stderr.write(r.stderr)
# pi-ai reports input excluding cache reads/writes; add them back for total prompt tokens.
sys.stderr.write(f"\n[usage] {calls} api call(s) · {tin + tread + twrite} in ({tread} cached, {twrite} cache writes) + {tout} out tokens\n")
with open(".eval-dsh-events.jsonl", "w") as f:
    f.write(r.stdout)
sys.exit(r.returncode)
