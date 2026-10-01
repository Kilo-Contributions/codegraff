#!/usr/bin/env python3
"""Run OpenCode 2 headless on one eval task and report like graff does.

usage: opencode2_run.py PROVIDER/MODEL PROMPT     (cwd = the task sandbox)

The task's `.mcp.json` becomes this directory's `opencode.json` `mcp` block
(OpenCode does not read `.mcp.json`). The final assistant text goes to stdout;
a graff-format `[usage]` line goes to stderr, read back from OpenCode's own
session database (input there excludes cache reads and writes, so they are
added back to make the total prompt tokens). stdin is empty: OpenCode appends
piped stdin to the prompt.
"""
import json, os, sqlite3, subprocess, sys

# OpenCode 2 is the @opencode/cli package; an `opencode` on PATH may be a 1.x install.
OC2 = os.environ.get("OPENCODE2_BIN", "opencode")
model, prompt = sys.argv[1], sys.argv[2]
cwd = os.getcwd()

if os.path.exists(".mcp.json"):
    servers = json.load(open(".mcp.json")).get("mcpServers", {})
    mcp = {name: {"type": "local", "command": [spec["command"], *spec.get("args", [])], "enabled": True}
           for name, spec in servers.items()}
    json.dump({"$schema": "https://opencode.ai/config.json", "mcp": mcp}, open("opencode.json", "w"))

r = subprocess.run([OC2, "run", "--standalone", "--auto", "--format", "json", "-m", model, prompt],
                   stdin=subprocess.DEVNULL, capture_output=True, text=True)
texts = []
for line in r.stdout.splitlines():
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if ev.get("type") == "text":
        texts.append((ev.get("part") or {}).get("text", ""))
print(texts[-1] if texts else "")
sys.stderr.write(r.stderr)

db_path = os.path.join(os.environ["HOME"], ".local/share/opencode/opencode.db")
try:
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    dirs = {cwd, os.path.realpath(cwd), "/private" + cwd if cwd.startswith("/tmp/") else cwd}
    q = ",".join("?" * len(dirs))
    row = db.execute(f"select id, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write "
                     f"from session_v2 where directory in ({q}) order by time_created desc limit 1", tuple(dirs)).fetchone()
    if row:
        sid, tin, tout, treason, tread, twrite = row
        calls = db.execute("select count(*) from session_message where session_id=? and type='assistant'", (sid,)).fetchone()[0]
        total_in = (tin or 0) + (tread or 0) + (twrite or 0)
        sys.stderr.write(f"\n[usage] {calls} api call(s) · {total_in} in ({tread or 0} cached, {twrite or 0} cache writes) + {(tout or 0) + (treason or 0)} out tokens\n")
except sqlite3.Error as e:
    sys.stderr.write(f"opencode2_run: usage unavailable: {e}\n")
sys.exit(r.returncode)
