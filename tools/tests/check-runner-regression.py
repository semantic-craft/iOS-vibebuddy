#!/usr/bin/env python3
"""Check report regressions: failure, no selected tests, skipped work and source drift."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

repo = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("checks", repo / "tools/check.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


def run(name, command_list, states=None, profile="docs"):
    with tempfile.TemporaryDirectory(prefix="vb-check-report-") as temporary:
        output = Path(temporary) / "evidence"
        captured = io.StringIO()
        with patch.object(sys, "argv", ["check.py", profile, "--output", str(output), "--json"]), \
             patch.object(checks, "commands", return_value=command_list), \
             patch.object(checks, "source_state", side_effect=states or [{"head": "fixture"}] * 2), \
             contextlib.redirect_stdout(captured), contextlib.redirect_stderr(io.StringIO()):
            result = checks.main()
        report = json.loads((output / "results.json").read_text())
        assert json.loads(captured.getvalue()) == report, name
        assert result == report["exit_code"], name
        return result, report


failure = [sys.executable, "-c", "raise SystemExit(7)"]
result, report = run("failed command", [failure, ["must-not-run"]])
assert result != 0 and report["checks"][0]["exit_code"] == 7
assert report["not_run"] == [["must-not-run"]]
print("PASS failing command keeps its exit code and marks remaining work not run")

result, report = run("missing executable", [ ["vibebuddy-intentionally-missing-check"] ])
assert result != 0 and report["checks"][0]["exit_code"] == 127
print("PASS missing executable produces a failed report")

# Swift returns exit 0 for a nonexistent filter (reproduced with a real package).
no_match = [sys.executable, "-c", "print('warning: No matching test cases were run')"]
result, report = run("no Swift tests", [no_match], profile="kit")
assert result != 0 and report["checks"][0]["exit_code"] == 0
assert report["checks"][0]["verification_error"]
print("PASS zero-test Swift success is rejected")

positive = [sys.executable, "-c", "print('✔ Test run with 1 test in 1 suite passed after 0.001 seconds.')"]
result, report = run("executed Swift test", [positive], profile="kit")
assert result == 0
result, report = run("source drift", [positive], [{"head": "before"}, {"head": "after"}], profile="kit")
assert result != 0 and report["source_changed_during_run"]
print("PASS executed Swift test passes only with unchanged source")

result, report = run("explicit unavailable capability", [[sys.executable, "-c", "print('  SKIP hardware: unavailable')"]])
assert result == 0 and report["status"] == "passed_with_skips"
assert report["checks"][0]["skips"] == ["SKIP hardware: unavailable"]
print("PASS explicit skipped capability remains machine-readable")
