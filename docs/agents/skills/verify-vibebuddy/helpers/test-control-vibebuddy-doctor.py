#!/usr/bin/env python3
"""Exercise doctor's real curl deadline with a disposable loopback HTTP fixture."""
import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest


HELPER = Path(__file__).with_name("control-vibebuddy")
REPO = next(p for p in HELPER.parents if (p / "VibeBuddyMac/Package.swift").exists())


class DoctorDeadlineTests(unittest.TestCase):
    def run_doctor(self, delay=0, timeout=None, malformed=False):
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                if self.path == "/health":
                    code, body = 200, b"ok"
                elif not self.headers.get("Authorization"):
                    code, body = 401, b""
                else:
                    time.sleep(delay)
                    code = 200
                    body = b"invalid" if malformed else b'{"sessions":[],"sourceID":"fixture"}'
                self.send_response(code)
                self.end_headers()
                try:
                    self.wfile.write(body)
                except BrokenPipeError:
                    pass  # Expected when curl enforces the test deadline.

        with tempfile.TemporaryDirectory(prefix="doctor-regression-") as directory:
            root = Path(directory)
            state = root / "state"
            identity = state / "home/Library/Application Support/vibebuddy/source-id"
            identity.parent.mkdir(parents=True)
            identity.write_text("fixture")
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            # Load the real functions without dispatch. Only platform/process
            # checks are stubbed; HTTP, auth, JSON and exit semantics are real.
            harness = root / "harness.sh"
            harness.write_text(HELPER.read_text().split('\ncmd="${1:-}"')[0] + r'''
host_blocker() { return 1; }
load_env() {
  PORT="$TEST_PORT"; TOKEN=fixture; DAEMON_PID=$$; PAIR=0
  VIBEBUDDY_HOME="$STATE_DIR/home"; BINARY=""
}
pid_alive() { return 0; }
port_listener_pid() { echo "$$"; }
uname() { echo fixture; }
cmd_doctor
''')
            env = dict(os.environ, VERIFY_REPO=str(REPO), VERIFY_STATE_DIR=str(state),
                       VERIFY_EVIDENCE_DIR=str(root / "evidence"), TEST_PORT=str(server.server_port))
            env.pop("VERIFY_DOCTOR_SNAPSHOT_TIMEOUT", None)
            if timeout is not None:
                env["VERIFY_DOCTOR_SNAPSHOT_TIMEOUT"] = timeout
            try:
                return subprocess.run(["bash", str(harness)], env=env, text=True,
                                      capture_output=True, timeout=10)
            finally:
                server.shutdown()
                server.server_close()

    def test_cold_snapshot_exceeding_old_four_second_budget(self):
        result = self.run_doctor(delay=4.2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("snapshot_deadline_seconds=45", result.stdout)

    def test_configured_deadline_still_fails(self):
        result = self.run_doctor(delay=1.5, timeout="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("curl_exit=28 deadline=1s", result.stdout)

    def test_invalid_json_still_fails(self):
        result = self.run_doctor(malformed=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_unbounded_and_invalid_deadlines_rejected(self):
        for timeout in ("0", "121", "-1", "invalid", "01"):
            with self.subTest(timeout=timeout):
                result = self.run_doctor(timeout=timeout)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("integer from 1 to 120", result.stderr)


if __name__ == "__main__":
    unittest.main()
