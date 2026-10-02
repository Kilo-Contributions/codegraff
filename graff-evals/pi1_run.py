#!/usr/bin/env python3
"""Run Pi 1.0 headless (--mode json) on one eval task and report like graff does.

usage: pi1_run.py PROVIDER/MODEL PROMPT     (cwd = the task sandbox)

Each run gets a private HOME whose ~/.pi/agent/mcp.json holds the task's
.mcp.json servers, so parallel runs never share config. PI1_CODEMODE=1 turns
codemode on through settings ("defaultTools": ["+codemode"]); --tools is not
used because it replaces the whole tool selection and drops MCP tools.
PI1_MCP_EXPOSURE sets every MCP server's exposure: Pi's default, codemode,
reaches MCP tools only from codemode scripts; direct declares them as ordinary
tools, so codemode never starts. PI1_MODELS copies a models.json (a provider
definition) and PI1_AUTH an auth.json (a sign-in) into that HOME, and
PI1_THINKING passes --thinking. PI1_BIN picks the binary when `pi` on PATH is
an older release. The final assistant text goes to stdout; a graff-format
[usage] line goes to stderr, summed over assistant messages (input counts
cache reads and writes, so it is the whole prompt).
"""
import json, os, shutil, subprocess, sys, tempfile

PI = os.environ.get("PI1_BIN", "pi")
model, prompt = sys.argv[1], sys.argv[2]
provider, _, name = model.partition("/")
codemode = os.environ.get("PI1_CODEMODE") == "1"
cwd = os.getcwd()

home = tempfile.mkdtemp(prefix="pi1-home-")
agent = os.path.join(home, ".pi", "agent")
os.makedirs(agent)
if os.path.exists(".mcp.json"):
    servers = {}
    for server, spec in json.load(open(".mcp.json")).get("mcpServers", {}).items():
        args = [os.path.join(cwd, a) if os.path.exists(os.path.join(cwd, a)) else a for a in spec.get("args", [])]
        servers[server] = {k: v for k, v in {"command": spec["command"], "args": args, "env": spec.get("env"), "cwd": cwd,
                                             "exposure": os.environ.get("PI1_MCP_EXPOSURE")}.items() if v}
    json.dump({"mcpServers": servers}, open(os.path.join(agent, "mcp.json"), "w"))
if codemode:
    json.dump({"defaultTools": ["+codemode"]}, open(os.path.join(agent, "settings.json"), "w"))
if os.environ.get("PI1_MODELS"):
    shutil.copy(os.environ["PI1_MODELS"], os.path.join(agent, "models.json"))
if os.environ.get("PI1_AUTH"):
    shutil.copy(os.environ["PI1_AUTH"], os.path.join(agent, "auth.json"))
thinking = ["--thinking", os.environ["PI1_THINKING"]] if os.environ.get("PI1_THINKING") else []
env = dict(os.environ, HOME=home)
try:
    r = subprocess.run([PI, "-p", "--mode", "json", "--provider", provider, "--model", name,
                        "--no-session", *thinking, prompt], stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env)
finally:
    shutil.rmtree(home, ignore_errors=True)

answer, calls = "", 0
tin = cached = writes = tout = 0
for line in r.stdout.splitlines():
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    msg = ev.get("message") or {}
    if ev.get("type") == "message_end" and msg.get("role") == "assistant":
        calls += 1
        u = msg.get("usage") or {}
        tin += (u.get("input") or 0) + (u.get("cacheRead") or 0) + (u.get("cacheWrite") or 0)
        cached += u.get("cacheRead") or 0
        writes += u.get("cacheWrite") or 0
        tout += u.get("output") or 0
        text = "".join(c.get("text", "") for c in msg.get("content") or [] if c.get("type") == "text")
        if text.strip():
            answer = text
print(answer)
sys.stderr.write(r.stderr)
sys.stderr.write(f"\n[usage] {calls} api call(s) · {tin} in ({cached} cached, {writes} cache writes) + {tout} out tokens\n")
with open(".eval-pi1-events.jsonl", "w") as f:
    f.write(r.stdout)
sys.exit(r.returncode)
