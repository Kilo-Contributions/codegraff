#!/usr/bin/env python3
"""Each model response writes a `usage` trace event with the server's counts.

- `input_tokens` is what the server billed as input (cached and written
  tokens included), `cache_read_tokens` / `cache_write_tokens` / `output_tokens`
  are its split, and `chained` says whether the request was a held-socket delta
- the `api` event's `context_tokens` is the context meter and may differ; the
  cache hit rate is cache_read_tokens / input_tokens from `usage`
"""
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel

USAGE = {'prompt_tokens': 20000, 'completion_tokens': 17, 'total_tokens': 20017,
         'prompt_tokens_details': {'cached_tokens': 18432}}


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    temp = Path(tempfile.mkdtemp(prefix='graff-usage-trace-'))
    model = ScriptedModel([
        {'tool': 'todo_read', 'arguments': {}, 'usage': USAGE},
        {'text': 'done', 'usage': {'prompt_tokens': 21000, 'completion_tokens': 3, 'total_tokens': 21003}},
    ])
    try:
        work = temp / 'proj'
        work.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=str(temp), USERPROFILE=str(temp), AI_GATEWAY_API_KEY='local', GRAFF_NO_TELEMETRY='1',
                   GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
        port = model.start(0)
        env['GRAFF_VERCEL_URL'] = f'http://127.0.0.1:{port}/v1/chat/completions'
        run = subprocess.run([binary, '--model', 'vercel', '--old', '--no-lean', '--yolo', '-p', 'go'], cwd=work, env=env,
                             capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120)
        assert run.returncode == 0, run.stderr[-1500:]
        rows = []
        for path in sorted((work / '.graff' / 'traces').glob('*.jsonl')):
            rows += [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        usage = [r for r in rows if r.get('ev') == 'usage' and not r.get('from_sub')]
        api = [r for r in rows if r.get('ev') == 'api' and not r.get('is_error')]
        assert len(usage) == 2 and len(api) == 2, (usage, api)
        first = usage[0]
        assert first['input_tokens'] == 20000, first
        assert first['cache_read_tokens'] == 18432 and first['cache_write_tokens'] == 0, first
        assert first['output_tokens'] == 17 and first['chained'] is False, first
        assert first['provider'] == 'vercel' and first['model'], first
        assert usage[1]['input_tokens'] == 21000 and usage[1]['cache_read_tokens'] == 0, usage[1]
        print('PASS each response writes a usage event with the server input, cache read/write and output tokens', flush=True)
    finally:
        model.stop()
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == '__main__':
    main()
