#!/usr/bin/env python3
"""A saved view reaches an ACP client as structured metadata.

- a `render_html` result's completed `tool_call_update` carries
  `_meta["graff/view"] = {kind: "html", id, path}`; the id names the snapshot
  under `$HOME/.graff/views`, which holds the model's page byte-for-byte
- the text link stays in the content for clients that do not read `_meta`
- an ordinary tool result carries no `graff/view`
"""
import json, os, queue, shutil, subprocess, sys, tempfile, threading, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel

PAGE = '<!doctype html><title>Flow</title><h1 style="color:#059669">Flow</h1>'


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    temp = tempfile.mkdtemp(prefix='acp-view-meta-')
    proc = None
    model = ScriptedModel([
        {'tool': 'read_file', 'arguments': {'path': 'notes.txt'}},
        {'tool': 'render_html', 'arguments': {'html': PAGE}},
        {'text': 'Drew it.'},
    ])
    try:
        root = Path(temp)
        work = root / 'proj'
        work.mkdir()
        (work / 'notes.txt').write_text('plain notes\n')
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=temp, USERPROFILE=temp, AI_GATEWAY_API_KEY='local', GRAFF_NO_TELEMETRY='1',
                   GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
        port = model.start(0)
        env['GRAFF_VERCEL_URL'] = f'http://127.0.0.1:{port}/v1/chat/completions'
        proc = subprocess.Popen([binary, 'acp', '--model', 'vercel', '--old', '--no-lean'], cwd=work, env=env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                encoding='utf-8', errors='replace', start_new_session=os.name == 'posix')
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

        updates = []

        def wait(id, timeout=60):
            deadline = time.monotonic() + timeout
            while True:
                m = messages.get(timeout=max(.01, deadline - time.monotonic()))
                assert m is not None, 'graff acp exited'
                if m.get('method') == 'session/request_permission':
                    send({'id': m['id'], 'result': {'outcome': {'outcome': 'selected', 'optionId': 'allow_once'}}})
                if m.get('method') == 'session/update':
                    updates.append(m['params']['update'])
                if m.get('id') == id and 'method' not in m:
                    return m

        send({'id': 1, 'method': 'initialize', 'params': {'protocolVersion': 1, 'clientCapabilities': {'fs': {}}}})
        wait(1)
        send({'id': 2, 'method': 'session/new', 'params': {'cwd': str(work), 'mcpServers': []}})
        sid = wait(2)['result']['sessionId']
        send({'id': 3, 'method': 'session/prompt', 'params': {'sessionId': sid, 'prompt': [{'type': 'text', 'text': 'draw the flow'}]}})
        done = wait(3)
        assert done.get('result', {}).get('stopReason') == 'end_turn', done

        finished = [u for u in updates if u.get('sessionUpdate') == 'tool_call_update' and u.get('status') in ('completed', 'failed') and u.get('content')]
        views = [u for u in finished if (u.get('_meta') or {}).get('graff/view')]
        assert len(views) == 1, f'expected one view result, got {len(views)}: {finished}'
        view = views[0]['_meta']['graff/view']
        assert view['kind'] == 'html', view
        assert len(view['id']) == 32 and all(c in '0123456789abcdef' for c in view['id']), view
        saved = Path(temp) / '.graff' / 'views' / f"{view['id']}.html"
        assert saved.read_text() == PAGE, 'the id does not name the saved page'
        assert Path(view['path']).resolve() == saved.resolve(), view
        text = views[0]['content'][0]['content']['text']
        assert text.startswith('[Rendered view]('), text
        print('PASS a render_html result carries _meta graff/view {kind, id, path}; the id names the saved page; the text link stays', flush=True)

        plain = [u for u in finished if u is not views[0]]
        assert plain and not any((u.get('_meta') or {}).get('graff/view') for u in plain), plain
        print('PASS an ordinary tool result carries no graff/view', flush=True)
    finally:
        if proc and proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)
        model.stop()
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == '__main__':
    main()
