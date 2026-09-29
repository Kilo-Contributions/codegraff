#!/usr/bin/env python3
"""Local MCP servers start on first use, not with every session.

- the first session with a new server starts it (its tools are learned and cached)
- later sessions advertise the cached tools and never spawn the process
- the first tool call spawns it once, runs the legacy handshake, answers, and
  re-lists tools to refresh the cache
- GRAFF_MCP_EAGER=1, and "startup": "eager" on one entry, start at boot
- a server that fails to start on first use gives the model an error; the
  session keeps going
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
if os.environ.get("LAZY_FAIL_FILE") and os.path.exists(os.environ["LAZY_FAIL_FILE"]):
    rec({"event": "start-refused", "pid": os.getpid()}); sys.exit(3)
rec({"event": "start", "pid": os.getpid()})
def out(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    meth = m.get("method"); mid = m.get("id")
    rec({"event": "method", "method": meth, "pid": os.getpid()})
    if mid is None: continue
    if meth == "initialize":
        out({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "lazy", "version": "1"}}})
    elif meth == "server/discover":
        out({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    elif meth == "tools/list":
        out({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
            {"name": "echo", "description": "echo back", "inputSchema": {"type": "object", "properties": {}}}]}})
    elif meth == "tools/call":
        out({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "echo from pid %d" % os.getpid()}]}})
    else:
        out({"jsonrpc": "2.0", "id": mid, "result": {}})
"""


def events(log, name):
    if not log.exists():
        return []
    return [json.loads(l) for l in log.read_text().splitlines() if l.strip() and json.loads(l).get('server', name) == name]


class Slow(ScriptedModel):
    # --yolo joins MCP in the background after the first request; a short
    # delay plus a todo_read warm-up lets the join land before MCP is needed.
    def next_reply(self, body):
        time.sleep(1.5)
        return super().next_reply(body)


WARM = {'tool': 'todo_read', 'arguments': {}}


def run(binary, work, env, script, extra_env=None):
    model = Slow([WARM] + script)
    port = model.start(0)
    e = dict(env, GRAFF_VERCEL_URL=f'http://127.0.0.1:{port}/v1/chat/completions', **(extra_env or {}))
    try:
        r = subprocess.run([binary, '--model', 'vercel', '--old', '--no-lean', '--yolo', '-p', 'go'], cwd=work, env=e,
                       capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180)
        model.stderr = r.stderr
    finally:
        model.stop()
    return model


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    temp = Path(tempfile.mkdtemp(prefix='graff-mcp-lazy-'))
    try:
        (temp / 'server.py').write_text(SERVER)
        work = temp / 'proj'
        work.mkdir()
        logs = {n: temp / f'{n}.log' for n in ('lazy', 'pinned')}
        fail_flag = temp / 'refuse-start'
        cfg = {'mcpServers': {
            'lazy': {'command': sys.executable, 'args': [str(temp / 'server.py'), str(logs['lazy'])], 'env': {'LAZY_FAIL_FILE': str(fail_flag)}},
            'pinned': {'command': sys.executable, 'args': [str(temp / 'server.py'), str(logs['pinned'])], 'startup': 'eager'},
        }}
        (work / '.mcp.json').write_text(json.dumps(cfg))
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        # No GRAFF_MCP_CONFIG: an empty override is MCP's off-switch (#549). HOME is private.
        env.update(HOME=str(temp), AI_GATEWAY_API_KEY='local', GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off',
                   GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1', GRAFF_REPL_DEBUG='1')

        def starts(name):
            return [e for e in events(logs[name], name) if e['event'] == 'start']

        # 1. First session ever: nothing cached, so the server starts to learn its tools.
        run(binary, work, env, [{'text': 'hello'}])
        assert len(starts('lazy')) == 1, events(logs['lazy'], 'lazy')
        cache = json.loads((temp / '.codegraff/mcp-list-cache.json').read_text())
        # Both servers connect at once; each must keep its own entry.
        for n in ('lazy', 'pinned'):
            assert any(str(logs[n]) in k for k in cache['servers']), (n, cache)
        print('PASS a new server starts once so its tools can be learned and cached', flush=True)

        # 2. Later session, no MCP call: tools advertised from cache, process never spawned.
        before = len(starts('lazy'))
        model = run(binary, work, env, [{'text': 'hello again'}])
        assert len(starts('lazy')) == before, 'the lazy server started without being used\n' + \
            (temp / '.codegraff/mcp-list-cache.json').read_text()[:1500] + '\n' + model.stderr[-2500:]
        assert '[mcp:lazy] ready — 1 tool(s), starts on first use' in model.stderr, model.stderr[-800:]
        assert len(starts('pinned')) == 2, 'a "startup":"eager" server must still start with every session'
        print('PASS a cached server is registered from its cached tools but not spawned; "startup": "eager" still starts at boot', flush=True)

        # 3. First use spawns it once, handshakes (legacy), answers, and refreshes the cache.
        logs['lazy'].write_text('')
        stamp_before = json.loads((temp / '.codegraff/mcp-list-cache.json').read_text())
        model = run(binary, work, env, [
            {'tool': 'mcp__lazy__echo', 'arguments': {}},
            {'tool': 'mcp__lazy__echo', 'arguments': {}},
            {'text': 'done'},
        ])
        ev = events(logs['lazy'], 'lazy')
        assert len([e for e in ev if e['event'] == 'start']) == 1, ev
        methods = [e['method'] for e in ev if e['event'] == 'method']
        assert methods[:2] == ['initialize', 'notifications/initialized'], methods
        assert methods.count('tools/call') == 2 and 'tools/list' in methods, methods
        results = [m.get('content') for r in model.requests for m in r.get('messages', []) if m.get('role') == 'tool']
        assert any('echo from pid' in str(r) for r in results), results
        stamp_after = json.loads((temp / '.codegraff/mcp-list-cache.json').read_text())
        key = next(k for k in stamp_after['servers'] if str(logs['lazy']) in k)
        assert stamp_after['servers'][key]['fetched_unix_ms'] > stamp_before['servers'][key]['fetched_unix_ms'], 'cache not refreshed on wake'
        print('PASS the first call spawns it once, runs initialize before tools/call, answers both calls, refreshes the cache', flush=True)

        # 4. GRAFF_MCP_EAGER=1 starts every server at boot.
        logs['lazy'].write_text('')
        m4 = run(binary, work, env, [{'text': 'eager'}], {'GRAFF_MCP_EAGER': '1'})
        assert len(starts('lazy')) == 1, 'GRAFF_MCP_EAGER=1 did not start the server at boot: ' + m4.stderr[-600:]
        print('PASS GRAFF_MCP_EAGER=1 starts servers with the session', flush=True)

        # 5. A server that cannot start on first use: the model gets an error, the turn goes on.
        logs['lazy'].write_text('')
        fail_flag.write_text('1')
        model = run(binary, work, env, [
            {'tool': 'mcp__lazy__echo', 'arguments': {}},
            {'text': 'carried on'},
        ])
        results = [str(m.get('content')) for r in model.requests for m in r.get('messages', []) if m.get('role') == 'tool']
        assert any('MCP server lazy failed to start' in r for r in results), results
        assert any(e['event'] == 'start-refused' for e in events(logs['lazy'], 'lazy')), 'the wake was never attempted'
        assert len(model.requests) >= 2, 'the turn stopped at the failed start'
        print('PASS a server that fails to start on first use returns an error and the turn continues', flush=True)
    finally:
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == '__main__':
    main()
