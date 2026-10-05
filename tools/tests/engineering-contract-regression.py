#!/usr/bin/env python3
"""Consume real check/plan/receipt CLI output; no product process or private history."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(argv, expected, **kwargs):
    result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, **kwargs)
    assert result.returncode == expected, (argv, result.returncode, result.stderr)
    document = json.loads(result.stdout)
    assert document["exit_code"] == expected, document
    return document


def fingerprint(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}


with tempfile.TemporaryDirectory(prefix="vb-engineering-contract-") as temporary:
    root = Path(temporary)
    output = root / "evidence"
    check = [sys.executable, str(ROOT / "tools/check.py")]
    report = run([*check, "docs", "--json", "--output", str(output)], 0)
    assert report == json.loads((output / "results.json").read_text())
    assert report["checks"] and report["limitations"] and report["source_before"]
    assert all(c["status"] == "passed" for c in report["checks"])
    run([*check, "docs", "--json", "--output", str(output)], 2)
    run([*check, "missing-profile", "--json"], 2)
    run([*check, "docs", "--output", str(root / "absent"), "--filter", "not-valid", "--json"], 2)
    assert not (root / "absent").exists()
    print("PASS check JSON is consumable and equals results.json; argument errors are JSON/2")

    app = root / "candidate.app"
    binary = app / "Contents/MacOS/VibeBuddyMacApp"
    binary.parent.mkdir(parents=True)
    # A real harmless process, not a daemon/UI imitation. Never binds a port.
    shutil.copyfile("/bin/sleep", binary)
    binary.chmod(0o755)
    if sys.platform == "darwin":
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True, capture_output=True)
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "com.vibebuddy.mac",
                      "CFBundleShortVersionString": "fixture", "CFBundleVersion": "1"}, stream)
    deploy = ["/bin/bash", str(ROOT / "tools/redeploy-mac.sh")]
    before = fingerprint(root)
    plan = run([*deploy, "--plan", str(app), "--json"], 1)
    assert plan["dry_run"] and plan["effects"]["performed"] == []
    assert plan["effects"]["network"] == [] and "peer_check_required" in plan["blockers"]
    assert plan["checks_not_run"] and plan["effects"]["unknown"]
    run([*deploy, "--dry-run", str(app), "--json"], 1)
    run([*deploy, "--install", str(app), "--json"], 2)
    assert before == fingerprint(root), "planning or invalid install wrote fixture data"
    process = subprocess.Popen([str(binary), "30"])
    try:
        plan = run([*deploy, "--plan", str(app), "--peer-check-complete"], 1)
        peers = plan["shared_app"]["processes"]
        if any(p["pid"] == process.pid for p in peers):
            assert "other_app_instance" in plan["blockers"]
            print("PASS real isolated process detected as peer; plan blocks without signaling")
        else:
            assert "process_observation_unavailable" in plan["blockers"], plan
            print("SKIP real peer visibility: host denied process observation; correctly blocked as unknown")
        assert process.poll() is None, "plan stopped the isolated process"
        assert before == fingerprint(root)
    finally:
        process.terminate()
        process.wait(timeout=5)
    print("PASS dry-run leaves fixture, processes and configuration untouched")

    # Exercise the existing replacement transaction and consume its stdout + disk receipt.
    for mode, expected, stage, rollback in [
        ("success", 0, "complete", "not_needed"),
        ("health-failure", 1, "health", "restored"),
        ("restore-move-failure", 1, "health", "failed"),
    ]:
        fixture = root / mode
        (fixture / "candidate.app").mkdir(parents=True)
        (fixture / "Applications/VibeBuddyMacApp.app").mkdir(parents=True)
        (fixture / "candidate.app/version").write_text("new")
        (fixture / "Applications/VibeBuddyMacApp.app/version").write_text("old")
        (fixture / "running").touch()
        env = dict(os.environ, INSTALL_JSON="1")
        result = run(["/bin/bash", "tools/tests/deploy-mac-regression.sh", "--case", str(fixture), mode], expected, env=env)
        assert result["stage"] == stage and result["rollback"] == rollback, result
        assert result == json.loads((Path(result["recovery_directory"]) / "receipt.json").read_text())
        assert result["limitations"] and result["operation_id"]
    run([*deploy, "--install", str(root / "missing.app"), "--peer-check-complete", "--json"], 1)
    print("PASS success, rollback and recovery-required receipts match process exits and disk evidence")
