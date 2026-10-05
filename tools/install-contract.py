#!/usr/bin/env python3
"""Read-only installation plan and receipt serialization for redeploy-mac.sh."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from datetime import datetime, timezone


def identity(app):
    result = {"path": str(app), "exists": app.is_dir()}
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if not isinstance(info, dict) or any(
            info.get(key) is not None and not isinstance(info[key], str)
            for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")
        ):
            raise ValueError("candidate identity fields must be strings in a plist dictionary")
        result.update(bundle_id=info.get("CFBundleIdentifier"),
                      version=info.get("CFBundleShortVersionString"),
                      build=info.get("CFBundleVersion"))
        executable = app / "Contents/MacOS/VibeBuddyMacApp"
        result["executable_sha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
        result["executable"] = os.access(executable, os.X_OK)
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        result["error"] = str(exc)
    return result


def observe_processes(destination):
    """Same pgrep/lsof identity boundary as mac-app-runtime; never signals."""
    observed = []
    unknown = []
    reads = ["pgrep -x VibeBuddyMacApp", "lsof text mappings for matching PIDs",
             "lsof TCP :9876 LISTEN owners"]
    def read(args):
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as exc:
            unknown.append(str(exc))
            return ""
        if result.returncode not in (0, 1) or result.stderr.strip():
            unknown.append(f"{args[0]} inspection unavailable: {result.stderr.strip()}")
        return result.stdout
    for pid in read(["pgrep", "-x", "VibeBuddyMacApp"]).split():
        if not pid.isdigit():
            unknown.append("invalid process ID from pgrep")
            continue
        mappings = read(["lsof", "-nP", "-a", "-p", pid, "-d", "txt", "-Fn"])
        executable = next((line[1:] for line in mappings.splitlines()
                           if line.startswith("n") and line.endswith("/Contents/MacOS/VibeBuddyMacApp")), None)
        observed.append({"pid": int(pid), "executable": executable,
                         "at_destination": executable == str(destination / "Contents/MacOS/VibeBuddyMacApp")})
        if executable is None:
            unknown.append(f"PID {pid} executable not observable; may have exited")
    listeners = read(["lsof", "-nP", "-iTCP:9876", "-sTCP:LISTEN", "-t"]).split()
    return observed, sorted(set(listeners)), unknown, reads


def plan(candidate, destination, peer_checked=False):
    app = Path(candidate)
    dest = Path(destination)
    if not app.is_absolute():
        raise ValueError("candidate must be an absolute path")
    artifact = identity(app)
    peers, listeners, unknown, process_reads = observe_processes(dest)
    blockers = []
    if artifact.get("bundle_id") != "com.vibebuddy.mac" or not artifact.get("executable"):
        blockers.append("invalid_candidate")
    if dest.is_symlink():
        blockers.append("destination_is_symlink")
    lock = dest.parent / f".{dest.name}.install-lock"
    if lock.exists():
        blockers.append("installation_reserved")
    if any(not p["at_destination"] for p in peers):
        blockers.append("other_app_instance")
    owned = {str(p["pid"]) for p in peers if p["at_destination"]}
    if set(listeners) - owned:
        blockers.append("port_owned_by_other_process")
    if unknown:
        blockers.append("process_observation_unavailable")
    if not peer_checked:
        blockers.append("peer_check_required")
    return {
        "schema_version": 1, "operation": "install_plan", "dry_run": True,
        "observed_utc": datetime.now(timezone.utc).isoformat(),
        "status": "blocked" if blockers else "planned", "exit_code": int(bool(blockers)),
        "candidate": artifact, "destination": str(dest), "port": 9876,
        "data_directory": "~/Library/Application Support/vibebuddy",
        "shared_app": {"processes": peers, "listener_pids": listeners,
                       "peer_check_attested": peer_checked, "lock": str(lock)},
        "blockers": blockers,
        "effects": {"performed": [], "planned": ["copy and verify candidate", "stop installed app",
                    "retain previous.app", "replace bundle", "launch and verify unique :9876 owner"],
                    "reads": ["candidate Info.plist and executable", "destination symlink and lock existence",
                              *process_reads], "network": [],
                    "unknown": [*unknown, "physical device/peer ownership is not observable from processes",
                                "candidate launch may migrate state or use existing login configuration"]},
        "checks_not_run": ["signature verification", "candidate launch/health", "phone/Watch/voice acceptance"],
        "next_action": "Resolve blockers, coordinate peers, then run --install with --peer-check-complete; recheck at execution.",
        "rollback": "Installer retains previous.app; read receipt and recovery directory before retrying an unknown outcome.",
    }


def receipt(args):
    candidate, destination, work, stage, rollback, code, success = args
    result = {"schema_version": 1, "operation": "install", "exit_code": int(code),
              "status": "installed" if success == "1" and code == "0" else "failed",
              "stage": stage, "candidate": identity(Path(candidate)),
              "installed_artifact": identity(Path(destination)) if success == "1" and code == "0" else None,
              "destination": destination, "recovery_directory": work or None,
              "lock": str(Path(destination).parent / f".{Path(destination).name}.install-lock"),
              "error": None if success == "1" and code == "0" else {"code": "install_failed", "stage": stage},
              "operation_id": Path(work).name if work else None, "rollback": rollback,
              "finished_utc": datetime.now(timezone.utc).isoformat(),
              "limitations": ["No phone/Watch/voice acceptance", "SIGKILL/power loss may leave no final receipt; inspect lock owner.txt before retry"],
              "next_action": "Consume this receipt; on failure inspect recovery_directory and lock before retrying."}
    if work:
        try:
            (Path(work) / "receipt.json").write_text(json.dumps(result, indent=2) + "\n")
        except OSError as exc:
            result.update(status="unknown", exit_code=1,
                          error={"code": "receipt_write_failed", "message": str(exc)})
    print(json.dumps(result, indent=2))
    # The shell preserves the operation's original exit (including signals).
    # Only serialization failure changes it to a generic failure.
    return int(result["status"] == "unknown")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "receipt":
            sys.exit(receipt(sys.argv[2:]))
        else:
            value = plan(sys.argv[2], sys.argv[3], sys.argv[4] == "1")
            print(json.dumps(value, indent=2))
            sys.exit(value["exit_code"])
    except (OSError, ValueError, IndexError) as exc:
        print(json.dumps({"schema_version": 1, "status": "error", "exit_code": 1,
                          "error": {"code": "install_contract_unavailable", "message": str(exc)}}))
        sys.exit(1)
