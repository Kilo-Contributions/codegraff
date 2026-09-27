#!/usr/bin/env python3
"""Real ACP publication and goal state against local-only fixtures: a draft PR completes as an unverified handoff."""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from github_fixture import prepare
from mock_model import ScriptedModel


def tool(name, **arguments):
    return {'tool': name, 'arguments': arguments}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graff', default='zig-out/bin/graff')
    parser.add_argument('--only-default', action='store_true')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    binary = str(Path(args.graff).resolve())
    attempt = tool('attempt_completion', result='Draft handoff.')
    model = ScriptedModel([
        tool('todo_write', todos=[{'content': 'inspect exact-head CI', 'status': 'pending'}]),
        tool('bash', command='gh pr create --draft --title fixture --body-file notes.md'),
        tool('todo_write', todos=[{'content': 'provide draft handoff', 'status': 'completed'}]),
        attempt, {'text': 'Draft handoff.'},
    ])
    with tempfile.TemporaryDirectory(prefix='graff-pr-acp-') as temp:
        work = Path(temp)
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=temp, LMSTUDIO_API_KEY='local', GRAFF_NO_TELEMETRY='1',
                   GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
        prepare(work, env, {'checks': 'FAILURE', 'runs': 'failure'})
        model.start(1234)
        proc = None
        all_events = []
        try:
            proc = subprocess.Popen([binary, 'acp', '--model', 'lmstudio', '--old', '--yolo'],
                                    cwd=temp, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True, start_new_session=True)
            events = queue.Queue()
            def reader():
                for line in proc.stdout:
                    try: events.put(json.loads(line))
                    except ValueError: pass
                events.put(None)
            threading.Thread(target=reader, daemon=True).start()
            next_id = 0
            def call(method, params):
                nonlocal next_id
                next_id += 1
                proc.stdin.write(json.dumps(dict(jsonrpc='2.0', method=method, params=params, id=next_id))+'\n')
                proc.stdin.flush()
                deadline = time.monotonic()+40
                updates = []
                while True:
                    value = events.get(timeout=max(.01, deadline-time.monotonic()))
                    assert value is not None, 'ACP worker exited before replying'
                    all_events.append(value)
                    if value.get('id') == next_id:
                        assert 'error' not in value, value
                        return value, updates
                    updates.append(value)
            call('initialize', {'protocolVersion': 1})
            session, _ = call('session/new', {})
            sid = session['result']['sessionId']
            def prompt(text):
                return call('session/prompt', {'sessionId': sid, 'prompt': [{'type': 'text', 'text': text}]})
            def saved_goal():
                saves = list((work/'.graff/sessions').glob('*.session.json'))
                assert saves, 'ACP did not save its session'
                current = max(saves, key=lambda p: p.stat().st_mtime_ns)
                return json.loads(current.read_text())['goal']
            prompt('/goal Deliver a PR with passing current-head CI')
            assert not model.requests, 'Slash goal command was sent to the model'
            _, updates = prompt('Run the publication fixture and complete the task.')
            assert saved_goal()['status'] == 'complete', saved_goal()
            assert 'Draft handoff \u2014 CI is not verified.' in json.dumps(updates) or 'Draft handoff — CI is not verified.' in json.dumps(updates, ensure_ascii=False), updates
            assert 'completion deferred' not in json.dumps(model.requests), 'a draft handoff was deferred'
            print('PASS ACP default: a draft PR completes as a labeled unverified handoff with no user command', flush=True)
            if args.only_default:
                return
            before = len(model.requests)
            prompt('/pr-acceptance draft')
            assert len(model.requests) == before, 'removed /pr-acceptance was sent to the model'
            print('PASS ACP /pr-acceptance is gone and never reaches the model', flush=True)
        finally:
            if args.evidence:
                args.evidence.mkdir(parents=True, exist_ok=True)
                (args.evidence/'acp-events.json').write_text(json.dumps(all_events, indent=2))
                (args.evidence/'model-requests.json').write_text(json.dumps(model.requests, indent=2))
                for name in ('traces', 'trajectories'):
                    source = work/'.graff'/name
                    if source.exists():
                        import shutil
                        shutil.copytree(source, args.evidence/name, dirs_exist_ok=True)
            if proc:
                try: os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                proc.wait(timeout=3)
                for pipe in (proc.stdin, proc.stdout):
                    if pipe: pipe.close()
            model.stop()


if __name__ == '__main__':
    main()
