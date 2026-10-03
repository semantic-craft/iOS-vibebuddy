#!/usr/bin/env python3
"""THROWAWAY PROTOTYPE: real read-only Antigravity signals, no production wiring.
Run: python3 VibeBuddyMac/Prototypes/AntigravityMonitor/probe.py OUTPUT_DIRECTORY
Raw synthetic-task output stays in the private output directory. Account identity,
process arguments, CSRF tokens, and existing conversation text are never exported.
"""
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import ssl
import subprocess
import sys
import time
import urllib.request


def shape(value, depth=0):
    if depth > 5:
        return type(value).__name__
    if isinstance(value, dict):
        return {k: shape(v, depth + 1) for k, v in value.items()}
    if isinstance(value, list):
        return [shape(value[0], depth + 1)] if value else []
    return type(value).__name__


def run(argv, timeout=30, cwd=None):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    return result.returncode, result.stdout, result.stderr


def desktop(method='GetAllCascadeTrajectories', body=None):
    """Deck-style discovery, restricted to current user's Antigravity bundle."""
    _, listing, _ = run(['ps', '-axo', 'uid=,pid=,args='])
    found = []
    for line in listing.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3 or fields[0] != str(os.getuid()):
            continue
        pid, args = fields[1:]
        if not any(p in args for p in ['/Antigravity.app/', '/Antigravity IDE.app/']):
            continue
        if '/language_server' not in args:
            continue
        match = re.search(r'--csrf_token(?:=|\s+)(\S+)', args)
        if not match:
            found.append({'pid': int(pid), 'result': 'missing_csrf'})
            continue
        token = match.group(1)
        _, sockets, _ = run(['/usr/sbin/lsof', '-nP', '-a', '-p', pid, '-iTCP', '-sTCP:LISTEN', '-Fn'])
        ports = sorted({int(m.group(1)) for m in re.finditer(r':(\d+)\s*$', sockets, re.M)})
        entry = {'pid': int(pid), 'attempts': []}
        for port in ports:
            # No proxy, redirects or remote host; TLS relaxation only this loopback connection.
            if method not in ('GetAllCascadeTrajectories', 'GetCascadeTrajectorySteps'):
                raise ValueError('Read-only prototype method allowlist')
            url = f'https://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/{method}'
            req = urllib.request.Request(url, data=json.dumps(body or {}).encode(), headers={
                'Content-Type': 'application/json', 'Connect-Protocol-Version': '1',
                'X-Codeium-Csrf-Token': token})
            class NoRedirect(urllib.request.HTTPRedirectHandler):
                def redirect_request(self, *args, **kwargs):
                    return None
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
            try:
                with opener.open(req, timeout=3) as response:
                    data = json.loads(response.read(8 * 1024 * 1024))
                if method == 'GetCascadeTrajectorySteps':
                    # Caller must supply the explicit synthetic probe conversation ID.
                    entry['attempts'].append({'port': port, 'ok': True, 'data': data})
                    break
                summaries = data.get('trajectorySummaries', {})
                entry['attempts'].append({'port': port, 'ok': True,
                    'summaryShape': shape(next(iter(summaries.values()), {})),
                    'sessions': [{'idHash': hashlib.sha256(k.encode()).hexdigest()[:12],
                                  'status': v.get('status'), 'stepCount': v.get('stepCount'),
                                  'keys': sorted(v.keys())} for k, v in summaries.items()]})
                break
            except Exception as error:
                entry['attempts'].append({'port': port, 'ok': False,
                    'errorType': type(error).__name__, 'httpCode': getattr(error, 'code', None)})
        found.append(entry)
    return found


def main():
    output = Path(sys.argv[1]).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    report = {'prototype': True, 'startedAt': time.time()}
    agy = str(Path.home() / '.local/bin/agy')
    report['cliVersion'] = run([agy, '--version'])[1].strip()
    print('Reading quota and desktop RPC...', flush=True)
    code, stdout, _ = run([agy, '-p', '/usage', '--output-format', 'json'])
    quota = json.loads(stdout)
    report['quota'] = {'exitCode': code, 'status': quota.get('status'),
        'groups': quota.get('command', {}).get('data', {}).get('groups', []),
        'tokenUsage': quota.get('usage'), 'numTurns': quota.get('num_turns')}
    report['desktop'] = desktop()
    report['brainSources'] = []
    for root in (Path.home() / '.gemini').glob('*/brain'):
        logs = list(root.glob('*/.system_generated/logs/transcript.jsonl'))
        report['brainSources'].append({'source': root.parent.name, 'transcriptCount': len(logs)})
    (output / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2), flush=True)


if __name__ == '__main__':
    main()
