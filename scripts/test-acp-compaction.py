#!/usr/bin/env python3
"""Offline: /compact over ACP reports compaction_update only to clients that
advertise clientCapabilities.session.compaction (ACP v1)."""
import json, os, queue, signal, subprocess, sys, tempfile, threading, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel


def run(binary, opted):
    script = [{'text': 'A hash map stores key/value pairs.'}, {'text': 'Summary: the user asked about hash maps; answered.'}]
    model = ScriptedModel(script)
    with tempfile.TemporaryDirectory(prefix='acp-compaction-') as temp:
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        config = Path(temp) / 'mcp.json'
        config.write_text('{"mcpServers":{}}')
        env.update(HOME=temp, AI_GATEWAY_API_KEY='local', GRAFF_MCP_CONFIG=str(config), GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
        port = model.start(0)
        env['GRAFF_VERCEL_URL'] = f'http://127.0.0.1:{port}/v1/chat/completions'
        proc = subprocess.Popen([binary, 'acp', '--model', 'vercel', '--old', '--no-lean', '--yolo'], cwd=temp, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        messages = queue.Queue()
        threading.Thread(target=lambda: [messages.put(l) for l in proc.stdout] and messages.put(None), daemon=True).start()

        def call(id, method, params):
            proc.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}) + '\n')
            proc.stdin.flush()
            updates, deadline = [], time.monotonic() + 30
            while True:
                line = messages.get(timeout=max(.01, deadline - time.monotonic()))
                assert line is not None, 'ACP worker exited'
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if m.get('id') == id and 'method' not in m:
                    return m, updates
                u = m.get('params', {}).get('update', {})
                if u.get('sessionUpdate', '').startswith('compaction'):
                    updates.append(u)
        try:
            caps = {'session': {'compaction': {}}} if opted else {}
            call(1, 'initialize', {'protocolVersion': 1, 'clientCapabilities': caps})
            result, _ = call(2, 'session/new', {'cwd': temp, 'mcpServers': []})
            sid = result['result']['sessionId']
            call(3, 'session/prompt', {'sessionId': sid, 'prompt': [{'type': 'text', 'text': 'What is a hash map?'}]})
            reply, updates = call(4, 'session/prompt', {'sessionId': sid, 'prompt': [{'type': 'text', 'text': '/compact'}]})
            assert reply.get('result', {}).get('stopReason') == 'end_turn', reply
            if not opted:
                assert updates == [], updates
                print('PASS ACP compaction: no updates for a client without the capability', flush=True)
                return
            assert [u['status'] for u in updates] == ['in_progress', 'completed'], updates
            assert updates[0]['compactionId'] == updates[1]['compactionId'], updates
            summary = updates[1]['summary'][0]
            assert summary['type'] == 'text' and summary['text'].strip(), updates
            print('PASS ACP compaction: in_progress then completed with the summary', flush=True)
        finally:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=3)
            model.stop()


if __name__ == '__main__':
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    run(binary, True)
    run(binary, False)
