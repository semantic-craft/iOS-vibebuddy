#!/usr/bin/env python3
"""THROWAWAY: project real captured signals into a small reviewable snapshot.
No timers infer completion; this is evidence replay, NOT a production monitor.
python3 VibeBuddyMac/Prototypes/AntigravityMonitor/replay.py EVIDENCE_DIRECTORY
"""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
read = lambda name: json.loads((root / name).read_text())
quota = read('read-only/report.json')['quota']
windows = [{'group': group['name'], 'id': b['id'], 'window': b['window'],
            'remainingPercent': round(b['remaining_fraction'] * 100, 2), 'resetAt': b.get('reset_time')}
           for group in quota['groups'] for b in group['buckets'] if b.get('remaining_fraction') is not None]
cli_wait = read('cli-wait.json')
last = cli_wait['transcriptRows'][-1]
calls = last.get('tool_calls', [])
questions = []
for call in calls:
    if call.get('name') == 'ask_question':
        value = call.get('args', {}).get('questions', [])
        questions.extend(json.loads(value) if isinstance(value, str) else value)
cli_result = read('antigravity-cli-final-transcript.json')
headless = read('cli-read/report.json')

def desktop_steps(filename):
    return next(a['data']['steps'] for server in read(filename)
                for a in server.get('attempts', []) if a.get('ok'))

waiting = [s for s in desktop_steps('desktop-wait-steps.json') if s['status'] == 'CORTEX_STEP_STATUS_WAITING']
cancelled = [s for s in desktop_steps('desktop-cancelled-steps.json') if s['status'] == 'CORTEX_STEP_STATUS_CANCELED']
result = {'prototype': True, 'mode': 'captured-real-evidence-replay', 'quota': windows,
    'tightestWindow': min(windows, key=lambda w: w['remainingPercent']),
    'observations': [
        {'source': 'CLI interactive', 'phase': 'question visibly open in terminal',
         'state': 'needsResponse' if questions else 'unknown', 'waitKind': 'question',
         'questions': questions, 'controlChannel': 'none',
         'boundary': 'Unresolved ask_question in transcript, corroborated by actual terminal; no silence timeout.'},
        {'source': 'CLI interactive', 'phase': 'answered in original terminal',
         'lastResult': cli_result[-1].get('content'), 'lastRowStatus': cli_result[-1].get('status'),
         'boundary': 'Terminal visibly idle. Transcript row DONE alone is not an authoritative turn boundary.'},
        {'source': 'CLI headless', 'phase': 'real task completed',
         'state': 'done' if headless['resultStatus'] == 'SUCCESS' and any(h.get('fullyIdle') for h in headless['hooks']) else 'unknown',
         'fullResultMatches': headless.get('transcript', {}).get('finalResponseMatches'),
         'boundary': 'Result SUCCESS plus Stop fullyIdle corroborate this completion.'},
        {'source': 'Desktop', 'phase': 'question visibly open in app',
         'state': 'needsResponse' if waiting else 'unknown', 'waitKind': 'question',
         'controlChannel': 'none', 'summaryStatus': 'RUNNING',
         'questions': [s.get('requestedInteraction', {}) for s in waiting],
         'boundary': 'Step WAITING overrides coarse RUNNING, with app UI corroboration.'},
        {'source': 'Desktop', 'phase': 'app reports cancelled execution',
         'state': 'done' if cancelled else 'unknown', 'outcome': 'cancelled',
         'successNotification': False,
         'boundary': 'Explicit CANCELED step; final transcript still omits the cancelled question result.'}
    ]}
(root / 'normalized.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
print(json.dumps(result, ensure_ascii=False, indent=2))
