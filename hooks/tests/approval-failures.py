#!/usr/bin/env python3
"""Replay real HTTP failure paths; no daemon, agent login or production token."""
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time

HOOK = Path(__file__).resolve().parents[1] / 'approval-hook.sh'

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

class Handler(http.server.BaseHTTPRequestHandler):
    mode = ''
    def log_message(self, *_): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        mode = self.server.mode
        if mode == 'timeout':
            time.sleep(32)
            return
        body = {'allow': b'{"permission":"allow"}', 'deny': b'{"permission":"deny"}',
                '401': b'{"error":"unauthorized"}', 'empty': b'',
                'partial': b'{"permission":"allow"'}.get(mode, b'')
        self.send_response(401 if mode == '401' else 200)
        self.send_header('Content-Length', str(len(body) + (20 if mode == 'partial' else 0)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

def call(port, source='cursor'):
    # Empty explicit token and nonexistent token file prevent reading login state.
    env = {**os.environ, 'VIBEBUDDY_PORT': str(port), 'VIBEBUDDY_TOKEN': '',
           'VIBEBUDDY_TOKEN_FILE': '/nonexistent/vb-approval-test', 'GROK_HOOK_EVENT': ''}
    return subprocess.run(['/bin/sh', str(HOOK), source], input=b'{"tool_name":"Shell"}',
                          env=env, capture_output=True, timeout=36)

with Server(('127.0.0.1', 0), Handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    for mode in ['empty', '401', 'partial', 'allow', 'deny', 'timeout']:
        server.mode = mode
        started = time.monotonic()
        result = call(server.server_port)
        if mode in ('allow', 'deny'):
            assert result.returncode == 0 and json.loads(result.stdout) == {'permission': mode}, (mode, result)
        else:
            assert result.returncode == 1 and not result.stdout, (mode, result)
        assert time.monotonic() - started < 35
        print(f'PASS Cursor {mode}', flush=True)
    server.mode = '401'
    result = call(server.server_port, 'claude')
    assert result.returncode == 0 and not result.stdout
    print('PASS Claude failure retains exit 0', flush=True)
    server.shutdown()
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    unreachable = sock.getsockname()[1]
result = call(unreachable)
assert result.returncode == 1 and not result.stdout
print('PASS Cursor unreachable', flush=True)
