import json, subprocess, sys, collections
# Ground truth straight from the fixture the task used.
reqs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_issues", "arguments": {}}}]
reqs += [{"jsonrpc": "2.0", "id": 10 + i, "method": "tools/call", "params": {"name": "list_comments", "arguments": {"id": f"ISS-{i}"}}} for i in range(1, 9)]
out = subprocess.run(["python3", "linear_fixture_mcp.py"], input="".join(json.dumps(r) + "\n" for r in reqs), capture_output=True, text=True, timeout=30).stdout
res = {json.loads(l)["id"]: json.loads(l)["result"] for l in out.splitlines() if l.strip()}
def body(r):
    data = json.loads(r["content"][0]["text"])
    return data if isinstance(data, list) else (data.get("issues") or data.get("comments") or data.get("nodes"))
issues = body(res[2])
comments = {f"ISS-{i}": len(body(res[10 + i])) for i in range(1, 9)}
exp = collections.defaultdict(lambda: {"issues": 0, "estimate": 0, "comments": 0})
for it in issues:
    e = exp[str(it["priority"])]
    e["issues"] += 1; e["estimate"] += it["estimate"]; e["comments"] += comments[it["id"]]
got = {str(k): {kk: int(vv) for kk, vv in v.items() if kk in ("issues", "estimate", "comments")} for k, v in json.load(open("rollup.json")).items()}
sys.exit(0 if got == dict(exp) else f"rollup.json {got} != {dict(exp)}")
