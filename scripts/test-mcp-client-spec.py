#!/usr/bin/env python3
"""MCP client behavior against scripted servers (stdio and Streamable HTTP).

- tools/list pagination: every page's tools are registered (nextCursor)
- tools/call carries _meta.progressToken
- notifications/tools/list_changed during a call re-lists before the next request
- input_required (MRTR): the call is retried with inputResponses + requestState
- a dropped SSE stream is resumed with GET + Last-Event-ID
- ACP session/cancel during a hung MCP call ends the turn at once and sends
  notifications/cancelled (stdio and legacy HTTP)
"""
import json, os, queue, shutil, signal, subprocess, sys, tempfile, threading, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel

DELAY = 0.6  # model latency: deferred MCP boot joins after the first request

STDIO_SERVER = r'''
import sys, json, os, time
LOG = os.environ['FAKE_MCP_LOG']
def log(x):
    with open(LOG, 'a') as f: f.write(json.dumps(x) + "\n")
def out(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def tool(n): return {"name": n, "description": "fake " + n, "inputSchema": {"type": "object", "properties": {}}}
added = False
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    log(m)
    mid = m.get('id'); meth = m.get('method')
    if mid is None: continue
    if meth == 'initialize':
        out({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-11-25", "capabilities": {"tools": {"listChanged": True}}, "serverInfo": {"name": "fake", "version": "1"}}})
    elif meth == 'server/discover':
        out({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    elif meth == 'tools/list':
        if (m.get('params') or {}).get('cursor') is None:
            out({"jsonrpc": "2.0", "id": mid, "result": {"tools": [tool("slow"), tool("ask"), tool("hang")], "nextCursor": "p2"}})
        else:
            out({"jsonrpc": "2.0", "id": mid, "result": {"tools": [tool("page2tool")] + ([tool("added")] if added else [])}})
    elif meth == 'tools/call':
        p = m.get('params') or {}; name = p.get('name'); tok = (p.get('_meta') or {}).get('progressToken')
        if name == 'slow':
            out({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": tok, "progress": 1, "total": 2}})
            added = True
            out({"jsonrpc": "2.0", "method": "notifications/tools/list_changed", "params": {}})
            out({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "slow done"}]}})
        elif name == 'ask':
            if 'inputResponses' in p:
                out({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "ask done state=" + str(p.get('requestState'))}]}})
            else:
                out({"jsonrpc": "2.0", "id": mid, "result": {"resultType": "input_required", "inputRequests": {"q": {"method": "elicitation/create", "params": {"mode": "form", "message": "Name?", "requestedSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}}}}, "requestState": "st-1"}})
    else:
        out({"jsonrpc": "2.0", "id": mid, "result": {}})
'''

HTTP_SERVER = r'''
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
LOG = os.environ['FAKE_MCP_LOG']; SID = 'sess-1'; state = {'added': False}
def log(x):
    with open(LOG, 'a') as f: f.write(json.dumps(x) + "\n")
def tool(n): return {"name": n, "description": "fake " + n, "inputSchema": {"type": "object", "properties": {}}}
class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def _json(self, code, obj, extra=None):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header('content-type', 'application/json'); self.send_header('content-length', str(len(b)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(b)
    def _sse(self):
        self.send_response(200); self.send_header('content-type', 'text/event-stream'); self.send_header('connection', 'close'); self.end_headers()
    def _event(self, eid, obj):
        self.wfile.write(("id: %s\ndata: %s\n\n" % (eid, json.dumps(obj))).encode()); self.wfile.flush()
    def do_GET(self):
        log({'GET': True, 'last_event_id': self.headers.get('last-event-id')})
        if self.headers.get('last-event-id') == '2':
            self._sse(); self._event('3', {"jsonrpc": "2.0", "id": state.get('slow_id', 0), "result": {"content": [{"type": "text", "text": "slowhttp done via resume"}]}}); self.close_connection = True
        else:
            self._json(405, {"error": "no"})
    def do_POST(self):
        m = json.loads(self.rfile.read(int(self.headers.get('content-length', 0)))); log(m)
        meth = m.get('method'); mid = m.get('id')
        if meth == 'initialize':
            return self._json(200, {"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-11-25", "capabilities": {"tools": {"listChanged": True}}, "serverInfo": {"name": "fakehttp", "version": "1"}}}, {'mcp-session-id': SID})
        if self.headers.get('mcp-session-id') != SID:
            return self._json(400, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": "no session"}})
        if mid is None:
            self.send_response(202); self.send_header('content-length', '0'); self.end_headers(); return
        if meth == 'tools/list':
            return self._json(200, {"jsonrpc": "2.0", "id": mid, "result": {"tools": [tool('slowhttp'), tool('hanghttp')] + ([tool('addedhttp')] if state['added'] else [])}})
        if meth == 'tools/call':
            name = (m.get('params') or {}).get('name')
            if name == 'slowhttp':
                state['slow_id'] = mid; state['added'] = True
                self._sse()
                self._event('1', {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": mid, "progress": 1}})
                self._event('2', {"jsonrpc": "2.0", "method": "notifications/tools/list_changed", "params": {}})
                self.close_connection = True; return  # dropped before the reply
            if name == 'hanghttp':
                self._sse(); time.sleep(20); self.close_connection = True; return
        return self._json(200, {"jsonrpc": "2.0", "id": mid, "result": {}})
srv = ThreadingHTTPServer(('127.0.0.1', 0), H); print(srv.server_address[1], flush=True); srv.serve_forever()
'''


class SlowModel(ScriptedModel):
    def next_reply(self, body):
        time.sleep(DELAY)
        return super().next_reply(body)


def read_log(path):
    if not os.path.exists(path):
        return []
    return [json.loads(l) for l in open(path) if l.strip()]


class Env:
    def __init__(self, servers):
        self.temp = tempfile.mkdtemp(prefix='mcp-client-spec-')
        cfg = Path(self.temp) / 'mcp.json'
        cfg.write_text(json.dumps({"mcpServers": servers}))
        self.env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        self.env.update(HOME=self.temp, AI_GATEWAY_API_KEY='local', GRAFF_MCP_CONFIG=str(cfg), GRAFF_NO_TELEMETRY='1',
                        GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')

    def model(self, script):
        m = SlowModel(script)
        self.env['GRAFF_VERCEL_URL'] = f'http://127.0.0.1:{m.start(0)}/v1/chat/completions'
        return m

    def cleanup(self):
        shutil.rmtree(self.temp, ignore_errors=True)


def tool_results(model):
    last = model.requests[-1] if model.requests else {}
    return [m.get('content') for m in last.get('messages', []) if m.get('role') == 'tool']


def oneshot(binary, e):
    subprocess.run([binary, '--model', 'vercel', '--old', '--no-lean', '--yolo', '-p', 'use the fake tools'],
                   cwd=e.temp, env=e.env, capture_output=True, text=True, timeout=120)


def acp_cancel(binary, e, log_path, hung_name):
    proc = subprocess.Popen([binary, 'acp', '--model', 'vercel', '--old', '--no-lean', '--yolo'], cwd=e.temp, env=e.env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                            start_new_session=os.name == 'posix')
    messages = queue.Queue()

    def read():
        for line in proc.stdout:
            try:
                messages.put(json.loads(line))
            except ValueError:
                pass
        messages.put(None)
    threading.Thread(target=read, daemon=True).start()

    def send(obj):
        proc.stdin.write(json.dumps({'jsonrpc': '2.0', **obj}) + '\n')
        proc.stdin.flush()

    def wait(i, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                m = messages.get(timeout=max(.01, deadline - time.monotonic()))
            except queue.Empty:
                return None
            if m is None:
                return None
            if m.get('id') == i and 'method' not in m:
                return m
        return None
    try:
        send({'id': 1, 'method': 'initialize', 'params': {'protocolVersion': 1, 'clientCapabilities': {}}})
        assert wait(1, 30), 'initialize'
        send({'id': 2, 'method': 'session/new', 'params': {'cwd': e.temp, 'mcpServers': []}})
        sid = wait(2, 30)['result']['sessionId']
        send({'id': 3, 'method': 'session/prompt', 'params': {'sessionId': sid, 'prompt': [{'type': 'text', 'text': 'go'}]}})
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and not any((m.get('params') or {}).get('name') == hung_name for m in read_log(log_path)):
            time.sleep(0.1)
        time.sleep(1.0)
        started = time.monotonic()
        send({'method': 'session/cancel', 'params': {'sessionId': sid}})
        done = wait(3, 10)
        elapsed = time.monotonic() - started
        assert done and done.get('result', {}).get('stopReason') == 'cancelled', done
        assert elapsed < 5, f'cancel took {elapsed:.1f}s'
        time.sleep(0.5)
        cancelled = [m for m in read_log(log_path) if m.get('method') == 'notifications/cancelled']
        call_ids = [m.get('id') for m in read_log(log_path) if (m.get('params') or {}).get('name') == hung_name]
        assert cancelled and cancelled[0]['params']['requestId'] in call_ids, (cancelled, call_ids)
    finally:
        if os.name == 'posix':
            os.killpg(proc.pid, signal.SIGKILL)
        else:
            proc.kill()
        proc.wait(timeout=10)


def stdio_cases(binary, server_py):
    log_path = str(Path(tempfile.mkdtemp()) / 'stdio.log')
    e = Env({"fake": {"command": sys.executable, "args": [server_py], "env": {"FAKE_MCP_LOG": log_path}}})
    try:
        model = e.model([{'tool': 'todo_read', 'arguments': {}}, {'tool': 'mcp__fake__slow', 'arguments': {}},
                         {'tool': 'mcp__fake__ask', 'arguments': {}}, {'text': 'Done.'}])
        oneshot(binary, e)
        model.stop()
        log = read_log(log_path)
        lists = [m for m in log if m.get('method') == 'tools/list']
        assert any((m.get('params') or {}).get('cursor') == 'p2' for m in lists), 'second page was never requested'
        calls = [m for m in log if m.get('method') == 'tools/call']
        assert calls and all(((m.get('params') or {}).get('_meta') or {}).get('progressToken') is not None for m in calls), calls
        assert len(lists) >= 4, 'list_changed did not trigger a re-list (both pages again)'
        results = tool_results(model)
        assert any('slow done' in str(r) for r in results), results
        assert any('ask done state=st-1' in str(r) for r in results), results
        assert any('inputResponses' in (m.get('params') or {}) for m in calls), 'MRTR retry missing'
        print('PASS MCP stdio: pagination, progress token, list_changed refresh, input_required retry', flush=True)

        open(log_path, 'w').close()
        e.model([{'tool': 'todo_read', 'arguments': {}}, {'tool': 'mcp__fake__hang', 'arguments': {}}, {'text': 'after'}])
        acp_cancel(binary, e, log_path, 'hang')
        print('PASS MCP stdio: ACP cancel stops a hung call and sends notifications/cancelled', flush=True)
    finally:
        e.cleanup()


def http_cases(binary, server_py):
    log_path = str(Path(tempfile.mkdtemp()) / 'http.log')
    srv = subprocess.Popen([sys.executable, server_py], stdout=subprocess.PIPE, text=True, env=dict(os.environ, FAKE_MCP_LOG=log_path))
    try:
        port = int(srv.stdout.readline())
        e = Env({"fakehttp": {"url": f"http://127.0.0.1:{port}/mcp"}})
        try:
            model = e.model([{'tool': 'todo_read', 'arguments': {}}, {'tool': 'mcp__fakehttp__slowhttp', 'arguments': {}}, {'text': 'Done.'}])
            oneshot(binary, e)
            model.stop()
            log = read_log(log_path)
            assert any(m.get('GET') and m.get('last_event_id') == '2' for m in log), 'no Last-Event-ID resume'
            assert any('slowhttp done via resume' in str(r) for r in tool_results(model)), tool_results(model)
            assert sum(1 for m in log if m.get('method') == 'tools/list') >= 2, 'SSE list_changed did not trigger a re-list'
            print('PASS MCP HTTP: dropped SSE resumed with Last-Event-ID; list_changed from the stream re-lists', flush=True)

            open(log_path, 'w').close()
            e.model([{'tool': 'todo_read', 'arguments': {}}, {'tool': 'mcp__fakehttp__hanghttp', 'arguments': {}}, {'text': 'after'}])
            acp_cancel(binary, e, log_path, 'hanghttp')
            print('PASS MCP HTTP: ACP cancel stops a hung call and sends notifications/cancelled', flush=True)
        finally:
            e.cleanup()
    finally:
        srv.kill()
        srv.wait(timeout=10)


if __name__ == '__main__':
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    work = Path(tempfile.mkdtemp(prefix='mcp-fakes-'))
    try:
        (work / 'stdio_server.py').write_text(STDIO_SERVER)
        (work / 'http_server.py').write_text(HTTP_SERVER)
        stdio_cases(binary, str(work / 'stdio_server.py'))
        http_cases(binary, str(work / 'http_server.py'))
    finally:
        shutil.rmtree(work, ignore_errors=True)
