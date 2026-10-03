#!/usr/bin/env python3
"""Offline production-dispatch regressions for v0.0.297. Never contacts GitHub.

Uses an isolated home/repository, a scripted local model and an argv-recording
stub gh. Listener checks start and stop only this script's own process group.
"""
import argparse
import json
import concurrent.futures
import threading
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "eval"))
from mock_model import ScriptedModel
from process_guard import run as bounded_run
from claim_ledger import path as claim_ledger_path

from github_fixture import GH, claim_ledger, prepare_review


def tool(command):
    return {"tool": "bash", "arguments": {"command": command}}


def completion(text="Verification complete."):
    return {"tool": "attempt_completion", "arguments": {"result": text}}


def stream_and_mcp(graff):
    with tempfile.TemporaryDirectory(prefix="graff-297-stream-") as temp:
        work = Path(temp)
        server = work / "slow_mcp.py"
        server.write_text("""import json, pathlib, sys, time
for line in sys.stdin:
    try: request=json.loads(line)
    except ValueError: continue
    if 'id' not in request: continue
    deadline=time.monotonic()+25
    while not pathlib.Path('second-native').exists() and time.monotonic()<deadline:time.sleep(.02)
    method=request.get('method')
    result={'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'fixture','version':'1'}} if method=='initialize' else {'tools':[]} if method=='tools/list' else {}
    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
""")
        (work / ".mcp.json").write_text(json.dumps({"mcpServers": {"withheld": {"command": sys.executable, "args": [str(server)]}}}))
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
        env.update(HOME=temp, LMSTUDIO_API_KEY="local", GRAFF_NO_TELEMETRY="1", GRAFF_FLEET="off",
                   GRAFF_NO_SMOLIFY="1", GRAFF_NO_CODEDB_GUARD="1", GRAFF_MCP_PROBE="0", NO_COLOR="1")
        raw = "Read the docs\ue200cite\ue202turn0search0\ue202turn1search2\ue201 today."
        class TimedModel(ScriptedModel):
            def next_reply(self, body):
                self.times.append(time.monotonic())
                return super().next_reply(body)
        model = TimedModel([tool("printf first > first-native"), tool("printf second > second-native"),
                            dict(completion(raw), argument_chunk_size=1)])
        model.times = []
        model.start(1234)
        try:
            done = bounded_run([str(graff), "--yolo", "--old", "--model", "lmstudio", "-p", "Run the scripted native tool fixture."],
                                  cwd=work, env=env, text=True, capture_output=True, timeout=45)
            assert done.returncode == 0, done.stderr[-3000:]
            assert (work / "first-native").exists() and (work / "second-native").exists(), done.stderr[-3000:]
            assert model.times[1] - model.times[0] < 5, model.times
            output = done.stdout + done.stderr
            assert "Read the docs today." in output, output[-4000:]
            assert all(mark not in output for mark in ("\ue200", "\ue201", "\ue202", "turn0search0", "turn1search2")), output[-4000:]
            print("PASS deferred MCP: second native tool ran before handshake release; fragmented citations stripped", flush=True)
        finally:
            model.stop()


def handoff(graff):
    with tempfile.TemporaryDirectory(prefix="graff-297-handoff-") as temp:
        work = Path(temp)
        (work / "bin").mkdir()
        gh = work / "bin/gh"
        gh.write_text(f"#!{sys.executable}\n" + GH.replace("GIT_EXE", shutil.which("git")))
        gh.chmod(0o755)
        bounded_run(["git", "init", "-q", "-b", "fixture"], cwd=work, check=True)
        bounded_run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture"], cwd=work, check=True)
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=work, text=True).strip()
        (work / "gh-state.json").write_text(json.dumps({"initial_head": head, "checks": "SUCCESS"}))
        (work / "notes.md").write_text("## Verification\nLocal: `python3 -m unittest` passed.\nRemote: passed.\n")
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
        env.update(HOME=temp, PATH=str(work / "bin") + os.pathsep + os.environ["PATH"], LMSTUDIO_API_KEY="local",
                   GRAFF_NO_TELEMETRY="1", GRAFF_FLEET="off", GRAFF_NO_SMOLIFY="1", GRAFF_NO_CODEDB_GUARD="1",
                   GRAFF_ACCORD="0", GRAFF_AUTO_ISOLATE="0", NO_COLOR="1")
        prepare_review(work, ['notes.md'])
        acquired, primed, transferred = (threading.Event() for _ in range(3))
        def peer(action, kind="publication", key="fixture", **extra):
            return {"tool": "peer_message", "arguments": dict(action=action, kind=kind, key=key, **extra)}
        class Peers(ScriptedModel):
            def next_reply(self, body):
                if 'committed_inputs' in json.dumps(body):
                    with self._lock: self.requests.append(body)
                    return {'text':json.dumps({'verdict':'supported','reason':'Controlled committed fixture review.'})}
                actor = "A" if "fixture-actor-A" in json.dumps(body) else "B"
                with self._lock:
                    self.requests.append(body)
                    step = self.counts[actor]
                    self.counts[actor] += 1
                if actor == "A":
                    if step == 0: return peer("claim")
                    if step == 1:
                        acquired.set()
                        assert primed.wait(35), "peer did not reach foreign claim gate"
                        ledger = json.loads(claim_ledger_path(work).read_text())
                        receiver = next(c["session"] for c in ledger if c["key"] == "independent")
                        return peer("handoff", session=receiver)
                    if step == 2:
                        transferred.set()
                        return tool("gh pr create --title fixture --body-file notes.md")
                else:
                    if step == 0:
                        assert acquired.wait(35)
                        return peer("claim", kind="branch", key="independent")
                    if step == 1: return tool("gh pr create --head unrelated --title fixture --body-file notes.md")
                    if step == 2: return tool("gh pr create --title fixture --body-file notes.md")
                    if step == 3:
                        primed.set()
                        assert transferred.wait(35)
                        return tool("gh pr create --title fixture --body-file notes.md")
                return {"text": "Handoff fixture complete."}
        model = Peers([])
        model.counts = {"A": 0, "B": 0}
        model.start(1234)
        def actor(name):
            return bounded_run([str(graff), "--json", "--yolo", "--old", "--model", "lmstudio"], cwd=work,
                                  env=env, text=True, capture_output=True, timeout=100,
                                  input=json.dumps({"type": "user", "text": "Run fixture-actor-" + name}) + "\n")
        try:
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                one, two = pool.submit(actor, "A"), pool.submit(actor, "B")
                a, b = one.result(), two.result()
            assert a.returncode == b.returncode == 0, (a.returncode, b.returncode, a.stderr[:1500], a.stderr[-500:], b.stderr[:1500], b.stderr[-500:])
            mutations = (work / "mutations.jsonl").read_text().splitlines() if (work / "mutations.jsonl").exists() else []
            assert len(mutations) == 2, (mutations, a.stdout[-4000:], b.stdout[-4000:])
            assert 'artifact claim held' in a.stdout and 'artifact claim held' in b.stdout, (a.stdout[-3000:], b.stdout[-3000:])
            print("PASS two live sessions: independent branch allowed; handoff enables receiver and revokes old owner", flush=True)
        finally:
            model.stop()


def orphan_listener(graff):
    if sys.platform not in ("darwin", "linux"):
        return
    import re
    import signal
    import socket
    with tempfile.TemporaryDirectory(prefix="graff-297-orphan-") as temp:
        work = Path(temp)
        child = work / "listener.py"
        child.write_text("""import json,os,pathlib,socket,time
s=socket.socket();s.bind(('127.0.0.1',0));s.listen()
pathlib.Path('listener.json').write_text(json.dumps({'pid':os.getpid(),'port':s.getsockname()[1]}))
while True: time.sleep(1)
""")
        env = dict(os.environ, HOME=temp, GRAFF_FIXTURE="legacy-listener", GRAFF_NO_TELEMETRY="1")
        bounded_run([sys.executable, "-c", "import subprocess,sys;subprocess.Popen([sys.executable,'listener.py'],start_new_session=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)"], cwd=work, env=env, check=True)
        info = work / "listener.json"
        deadline = time.monotonic() + 10
        while not info.exists() and time.monotonic() < deadline: time.sleep(.05)
        state = json.loads(info.read_text())
        pid, port = state['pid'], state['port']
        try:
            listing = bounded_run([str(graff), "servers", "list"], cwd=work, env=env, text=True, capture_output=True, timeout=30)
            token = re.search(rf"stop-suspect {pid} ([0-9a-f]+-[0-9a-f]+)", listing.stdout)
            assert token, listing.stdout[-3000:]
            bad = bounded_run([str(graff), "servers", "stop-suspect", str(pid), "stale-token"], cwd=work, env=env, text=True, capture_output=True, timeout=30)
            assert "unverifiable" in bad.stdout, bad.stdout
            with socket.create_connection(('127.0.0.1', port), timeout=2): pass
            stopped = bounded_run([str(graff), "servers", "stop-suspect", str(pid), token.group(1)], cwd=work, env=env, text=True, capture_output=True, timeout=30)
            assert "legacy listener stop: stopped" in stopped.stdout, stopped.stdout
            try:
                socket.create_connection(('127.0.0.1', port), timeout=.5).close()
                raise AssertionError("listener survived reported stop")
            except OSError: pass
            assert not (work / '.codegraff/jobs').exists(), "suspect was silently adopted"
            print("PASS legacy orphan: discovery, stale-token refusal, identity-bound explicit stop, no adoption", flush=True)
        finally:
            try: os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError: pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graff", type=Path, default=ROOT / "zig-out/bin/graff")
    args = parser.parse_args()
    orphan_listener(args.graff)
    handoff(args.graff)
    stream_and_mcp(args.graff)

if __name__ == "__main__":
    main()
