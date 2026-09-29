#!/usr/bin/env python3
"""Offline crash-survival regression (ADR 0218): background jobs outlive a
SIGKILLed graff, and resuming the session re-attaches them.

Graff A starts two background jobs, then dies mid-request with no shutdown.
One job finishes while no graff is running; the other is still running when
graff B resumes the session. B must deliver the first job's exit as a
completion notice, and its bash_output must wait for the second job and
report its real exit. Before ADR 0218 both died with A's pipes and B could
only call the handles "interrupted or unknown".
"""
import argparse, json, os, re, signal, subprocess, sys, tempfile, threading, time
from pathlib import Path
REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts/eval'))
from mock_model import ScriptedModel

EARLY = 'sleep 1; echo EARLY-DONE; exit 7'
LATE = 'sleep 5; echo LATE-DONE'


def wait_until(fn, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if fn(): return True
        time.sleep(.05)
    return False


def tool_text(body):
    return [m.get('content', '') for m in body.get('messages', []) if m.get('role') == 'tool']


def user_text(body):
    out = []
    for m in body.get('messages', []):
        if m.get('role') != 'user': continue
        c = m.get('content', '')
        out.append(c if isinstance(c, str) else json.dumps(c))
    return '\n'.join(out)


def job_id(text):
    found = re.search(r'\[job (\d+) started:', text)
    if not found: raise AssertionError(f'no started handle in {text[:300]!r}')
    return int(found.group(1))


class First(ScriptedModel):
    """Starts both jobs, then holds its third request open until killed."""
    def __init__(self):
        super().__init__([])
        self.ids, self.holding, self.release = [], threading.Event(), threading.Event()

    def next_reply(self, body):
        with self._lock:
            self.requests.append(body)
            n = len(self.requests)
        if n == 1:
            return {'tool': 'shell', 'arguments': {'action': 'run', 'command': EARLY, 'run_in_background': True}}
        if n == 2:
            self.ids.append(job_id(tool_text(body)[-1]))
            return {'tool': 'shell', 'arguments': {'action': 'run', 'command': LATE, 'run_in_background': True}}
        if n == 3:
            self.ids.append(job_id(tool_text(body)[-1]))
            self.holding.set()
            self.release.wait(30)
        return {'text': 'A done'}


class Second(ScriptedModel):
    """Reads what the resumed session delivered, then waits on the late job."""
    def __init__(self, late):
        super().__init__([])
        self.late, self.seen, self.done = late, {'users': ''}, threading.Event()

    def next_reply(self, body):
        with self._lock:
            self.requests.append(body)
            n = len(self.requests)
        # The notice lands at a step boundary: the first request, or the next
        # one if the re-attached pump published just after the first.
        self.seen['users'] += user_text(body)
        if n == 1:
            return {'tool': 'bash_output', 'arguments': {'id': self.late, 'wait_ms': 20000}}
        if n == 2:
            self.seen['late_output'] = tool_text(body)[-1]
            self.done.set()
            return {'text': 'B done'}
        return {'text': 'done'}


def start(binary, directory, model, name, extra):
    port = model.start(0)
    env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY') and not k.startswith(('GRAFF_', 'HARNESS_'))}
    env.update(HOME=str(directory / 'home'), AI_GATEWAY_API_KEY='local', GRAFF_FLEET='off',
               GRAFF_VERCEL_URL=f'http://127.0.0.1:{port}/v1/chat/completions', GRAFF_NO_TELEMETRY='1',
               GRAFF_NO_SMOLIFY='1', GRAFF_BEHAVIOR_UPLOAD='off', NO_COLOR='1')
    out = open(directory / (name + '.stdout'), 'w')
    err = open(directory / (name + '.stderr'), 'w')
    proc = subprocess.Popen([str(binary), '--json', '--yolo', '--old', '--no-lean', '--max-model-calls', '6', '--model', 'vercel', *extra],
                            cwd=directory, env=env, stdin=subprocess.PIPE, stdout=out, stderr=err, text=True, start_new_session=True)
    proc.stdin.write(json.dumps({'type': 'user', 'text': 'Run the scripted jobs and handle their results.'}) + '\n')
    proc.stdin.flush()
    return proc, out, err


def saved_session(directory, late):
    for path in (directory / '.graff/sessions').glob('*.session.json'):
        try:
            if str(late) in path.read_text(): return path.name[:-len('.session.json')]
        except OSError: pass
    return None


def kill_group(pid):
    try: os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError): pass


def run(binary, expect):
    directory = Path(tempfile.mkdtemp(prefix='graff-job-crash-'))
    os.chmod(directory, 0o700)
    (directory / 'home').mkdir(mode=0o700)
    running, models, leaders = [], [], []
    try:
        a = First(); models.append(a)
        proc_a, out_a, err_a = start(binary, directory, a, 'A', []); running.append((proc_a, out_a, err_a))
        assert a.holding.wait(30), 'A did not start both jobs'
        early, late = a.ids
        assert wait_until(lambda: saved_session(directory, late) is not None), 'A never saved its session'
        session = saved_session(directory, late)
        for job in (early, late):
            meta = directory / '.graff/job-output' / str(job) / 'meta.json'
            if wait_until(meta.exists, 5): leaders.append(json.loads(meta.read_text())['pid'])
        proc_a.kill(); proc_a.wait(timeout=5)  # abrupt: no defers, no jobsReap
        a.release.set()
        time.sleep(2)  # the early job ends while no graff runs

        b = Second(late); models.append(b)
        proc_b, out_b, err_b = start(binary, directory, b, 'B', ['--resume', session]); running.append((proc_b, out_b, err_b))
        finished = b.done.wait(40)
        users = b.seen.get('users', '')
        late_out = b.seen.get('late_output', '')
        checks = dict(
            early_notice=bool(re.search(rf'\[job {early} exited 7:', users)) and 'EARLY-DONE' in users,
            late_exit='exited with code 0' in late_out and 'LATE-DONE' in late_out,
        )
        proc_b.stdin.close()  # a clean end reaps the jobs and their captures
        proc_b.wait(timeout=20)
        left = list((directory / '.graff/job-output').glob('*')) if (directory / '.graff/job-output').exists() else []
        checks['captures_cleaned'] = not left
        passed = finished and all(checks.values())
        report = dict(binary=str(binary), session=session, early=early, late=late, passed=passed, **checks,
                      late_output=late_out[:300])
        (directory / 'receipt.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(dict(directory=str(directory), **report), indent=2))
        assert passed == (expect == 'pass'), f'expected {expect}, observed {passed}'
    finally:
        for model in models:
            if hasattr(model, 'release'): model.release.set()
        for process, out, err in running:
            if process.poll() is None: process.kill()
            process.wait(timeout=5)
            out.close(); err.close()
        for pid in leaders: kill_group(pid)  # each job leads its own group
        for model in models: model.stop()


if __name__ == '__main__':
    if os.name != 'posix':
        print('SKIP job crash/resume: POSIX process-group fixture')
        sys.exit(0)
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path, nargs='?', default=REPO / 'zig-out/bin/graff')
    parser.add_argument('--expect', choices=['pass', 'fail'], default='pass')
    args = parser.parse_args()
    run(args.binary.resolve(), args.expect)
