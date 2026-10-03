#!/usr/bin/env python3
"""THROWAWAY: bounded real agy task, project-local passive hooks; no production hooks.
python3 VibeBuddyMac/Prototypes/AntigravityMonitor/drive.py NEW_OUTPUT_DIRECTORY
"""
import hashlib
import json
import os
from pathlib import Path
import selectors
import shlex
import subprocess
import sys
import time

if len(sys.argv) > 1 and sys.argv[1] == 'hook':
    event, target = sys.argv[2:4]
    try:
        value = json.load(sys.stdin)
        with open(target, 'a') as out:
            out.write(json.dumps({'at': time.time(), 'event': event, 'payload': value}) + '\n')
    except Exception:
        pass
    print('{}')
    sys.exit(0)

output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=False, mode=0o700)
workspace = output / 'workspace'
(workspace / '.agents').mkdir(parents=True)
(workspace / 'fixture.txt').write_text('ANTIGRAVITY_PROTOTYPE_FIXTURE_20261004\n')
events = ['PreInvocation', 'PostInvocation', 'PostToolUse', 'Stop']
config = {}
for event in events:
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), 'hook', event, str(output / 'hooks.jsonl')])
    handler = {'type': 'command', 'command': command, 'timeout': 3}
    config[event] = [{'matcher': '*', 'hooks': [handler]}] if event == 'PostToolUse' else [handler]
(workspace / '.agents/hooks.json').write_text(json.dumps({'vibebuddy-prototype': config}))
prompt = ('This is an isolated monitor acceptance probe. Read fixture.txt with your file reading tool, '
          'then reply with exactly ANTIGRAVITY_PROTOTYPE_OK followed by the file contents. '
          'Do not edit files, run shell commands, browse the web, or delegate.')
if len(sys.argv) > 2 and sys.argv[2] == 'long':
    prompt = ('This is a monitor long-result integrity probe. Do not use any tools. '
              'Output exactly 80 numbered lines. Each line has the form '
              '"LINE 001: Antigravity monitor preserves the complete original result." '
              'Increment the three-digit number through 080. No introduction or code fence.')
argv = [str(Path.home() / '.local/bin/agy'), '-p', prompt, '--output-format', 'stream-json', '--print-timeout', '90s']
started = time.monotonic()
with (output / 'stderr.txt').open('w') as err, (output / 'stream.jsonl').open('w') as raw:
    proc = subprocess.Popen(argv, cwd=workspace, stdout=subprocess.PIPE, stderr=err, text=True)
    print('Synthetic read-only task PID', proc.pid, flush=True)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    stream = []
    deadline = time.monotonic() + 100
    try:
        while time.monotonic() < deadline:
            for key, _ in selector.select(0.5):
                line = key.fileobj.readline()
                if not line:
                    selector.unregister(key.fileobj)
                    continue
                raw.write(line)
                raw.flush()
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                stream.append(obj)
                if obj.get('event') in ('init', 'result') or len(stream) == 2:
                    print('event', obj.get('event'), 'after', round(time.monotonic()-started, 2), 'seconds', flush=True)
            if proc.poll() is not None and not selector.get_map():
                break
        if proc.poll() is None:
            proc.terminate()
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()
    finally:
        selector.close()
        if proc.poll() is None: proc.terminate(); proc.wait(timeout=5)

hooks = [json.loads(l) for l in (output / 'hooks.jsonl').read_text().splitlines()] if (output / 'hooks.jsonl').exists() else []
init = next((e for e in stream if e.get('event') == 'init'), {})
final = next((e.get('result', {}) for e in reversed(stream) if e.get('event') == 'result'), {})
cid = init.get('conversation_id') or final.get('conversation_id')
report = {'exitCode': proc.returncode, 'elapsedSeconds': round(time.monotonic()-started, 2),
    'conversationID': cid, 'events': [e.get('event') for e in stream], 'resultStatus': final.get('status'),
    'response': final.get('response'), 'responseLength': len(final.get('response') or ''),
    'hooks': [{'event': h['event'], 'keys': sorted(h['payload']),
        'fullyIdle': h['payload'].get('fullyIdle'), 'terminationReason': h['payload'].get('terminationReason')}
        for h in hooks]}
if cid:
    transcript = Path.home() / '.gemini/antigravity-cli/brain' / cid / '.system_generated/logs/transcript.jsonl'
    report['transcriptExists'] = transcript.exists()
    if transcript.exists():
        content = transcript.read_text()
        (output / 'transcript.jsonl').write_text(content)
        rows = [json.loads(l) for l in content.splitlines()]
        responses = [r.get('content','') for r in rows if r.get('type') == 'PLANNER_RESPONSE' and r.get('content')]
        report['transcript'] = {'rows': len(rows), 'types': sorted({r.get('type','') for r in rows}),
            'statuses': sorted({r.get('status','') for r in rows}),
            'finalResponseMatches': bool(responses) and responses[-1].strip() == (final.get('response') or '').strip()}
        full = transcript.with_name('transcript_full.jsonl')
        if full.exists():
            content = full.read_text()
            (output / 'transcript_full.jsonl').write_text(content)
            rows = [json.loads(l) for l in content.splitlines()]
            responses = [r.get('content','') for r in rows if r.get('type') == 'PLANNER_RESPONSE' and r.get('content')]
            report['fullTranscript'] = {'rows': len(rows),
                'finalResponseMatches': bool(responses) and responses[-1].strip() == (final.get('response') or '').strip(),
                'bodyLength': len(responses[-1]) if responses else 0}
(output / 'report.json').write_text(json.dumps(report, indent=2))
print(json.dumps({k:v for k,v in report.items() if k != 'response'}, indent=2))
