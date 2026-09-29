#!/usr/bin/env python3
"""A "shared": true MCP server runs once per machine for every session.

- two concurrent sessions calling the shared server reach ONE process: one
  start, one initialize (the second, even while the first is still at the
  server, is answered by the broker), every call
  answered with that process's pid, each session getting its own replies
- an ordinary server beside it still runs once per session
- when the sessions end, the broker exits on its idle timer: the server
  process is gone and its socket file removed
"""
import json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel

SERVER = r"""
import json, os, sys, time
log = sys.argv[1]
def rec(o):
    with open(log, "a") as f: f.write(json.dumps(o) + "\n")
rec({"event": "start", "pid": os.getpid()})
def out(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    meth = m.get("method"); mid = m.get("id")
    rec({"event": "method", "method": meth})
    if mid is None: continue
    if meth == "initialize":
        time.sleep(1)  # both sessions' initialize reach the broker before this answer
        out({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "s", "version": "1"}}})
    elif meth == "server/discover":
        out({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    elif meth == "tools/list":
        out({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": "echo", "description": "echo", "inputSchema": {"type": "object", "properties": {"tag": {"type": "string"}}}}]}})
    elif meth == "tools/call":
        tag = (m.get("params") or {}).get("arguments", {}).get("tag", "")
        out({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "pid %d tag %s" % (os.getpid(), tag)}]}})
    else:
        out({"jsonrpc": "2.0", "id": mid, "result": {}})
"""


class Slow(ScriptedModel):
    def next_reply(self, body):
        time.sleep(1.5)  # --yolo joins MCP after the first request; keep the sessions overlapping
        return super().next_reply(body)


def events(log):
    return [json.loads(l) for l in log.read_text().splitlines() if l.strip()] if log.exists() else []


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main():
    if os.name == 'nt':
        print('SKIP shared MCP servers are POSIX-only')
        return
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    temp = Path(tempfile.mkdtemp(prefix='graff-mcp-shared-'))
    try:
        (temp / 'server.py').write_text(SERVER)
        shared_log, solo_log = temp / 'shared.log', temp / 'solo.log'
        cfg = {'mcpServers': {
            'clock': {'command': sys.executable, 'args': [str(temp / 'server.py'), str(shared_log)], 'shared': True},
            'solo': {'command': sys.executable, 'args': [str(temp / 'server.py'), str(solo_log)]},
        }}
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=str(temp), AI_GATEWAY_API_KEY='local', GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off',
                   GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1', GRAFF_MCP_SHARED_IDLE_S='2')
        sock_dir = Path(f'/tmp/graff-{os.getuid()}')
        pre = set(sock_dir.glob('mcp-*.sock'))
        procs, models = [], []
        for name in ('a', 'b'):
            work = temp / name
            work.mkdir()
            (work / '.mcp.json').write_text(json.dumps(cfg))
            model = Slow([
                {'tool': 'todo_read', 'arguments': {}},
                {'tool': 'mcp__clock__echo', 'arguments': {'tag': f'{name}1'}},
                {'tool': 'mcp__clock__echo', 'arguments': {'tag': f'{name}2'}},
                {'tool': 'mcp__solo__echo', 'arguments': {'tag': name}},
                {'text': 'done'},
            ])
            port = model.start(0)
            e = dict(env, GRAFF_VERCEL_URL=f'http://127.0.0.1:{port}/v1/chat/completions')
            procs.append(subprocess.Popen([binary, '--model', 'vercel', '--old', '--no-lean', '--yolo', '-p', 'go'], cwd=work, env=e,
                                          stdout=subprocess.DEVNULL, stderr=open(temp / f'{name}.err', 'w')))
            models.append((name, model))
        # Note the broker's socket while the sessions run: it is removed once the
        # broker idles out (2s here), which can pass before the checks below.
        seen = set()
        deadline = time.time() + 240
        while any(p.poll() is None for p in procs) and time.time() < deadline:
            seen |= set(sock_dir.glob('mcp-*.sock')) - pre
            time.sleep(0.1)
        for p in procs:
            p.wait(timeout=10)
        for _, m in models:
            m.stop()

        ev = events(shared_log)
        starts = [e for e in ev if e['event'] == 'start']
        methods = [e['method'] for e in ev if e['event'] == 'method']
        errs = {n: (temp / f'{n}.err').read_text()[:600] for n, _ in models}
        assert len(starts) == 1, f'shared server started {len(starts)} times: {ev} {errs}'
        assert methods.count('initialize') == 1, f'initialize reached the server {methods.count("initialize")} times'
        assert methods.count('tools/call') == 4, methods
        pid = starts[0]['pid']
        for name, m in models:
            results = [str(x.get('content')) for r in m.requests for x in r.get('messages', []) if x.get('role') == 'tool']
            clock = [r for r in results if f'pid {pid} tag {name}' in r]
            assert len(clock) >= 2, f'session {name} did not get both of its own shared replies: {results}'
            other = 'b' if name == 'a' else 'a'
            assert not any(f'tag {other}1' in r or f'tag {other}2' in r for r in results), f'session {name} received the other session\'s reply'
        print('PASS two concurrent sessions share one process: one start, one initialize, each gets its own replies', flush=True)

        solo_starts = [e for e in events(solo_log) if e['event'] == 'start']
        assert len(solo_starts) == 2, f'an ordinary server should run once per session: {len(solo_starts)}'
        print('PASS an ordinary server beside it still runs once per session', flush=True)

        ours = seen
        assert ours, 'no broker socket was created'
        deadline = time.time() + 15
        while time.time() < deadline and alive(pid):
            time.sleep(0.5)
        time.sleep(0.5)
        assert not alive(pid), 'the shared server outlived its idle timeout'
        assert oct(sock_dir.stat().st_mode & 0o777) == '0o700', 'the socket directory must be private'
        assert not (set(sock_dir.glob('mcp-*.sock')) & ours), 'the broker left its socket behind'
        print('PASS the broker exits on its idle timer and cleans up', flush=True)
    finally:
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == '__main__':
    main()
