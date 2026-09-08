#!/usr/bin/env python3
"""Read-only Codex version/contract audit and thread-scoped source evidence.

No hook/config writes, no approval responses, no turn creation. The watch command
subscribes to a supplied task and prints metadata only, never prompts/tool output.
"""
import argparse
import collections
import importlib.util
import json
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("hook_trust", ROOT / "hooks/codex_hook_trust.py")
trust = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trust)


def emit(kind, **fields):
    print(json.dumps({"at": time.time(), "kind": kind, **fields}), flush=True)


def run(*args):
    return subprocess.check_output(args, text=True, timeout=30)


def audit():
    version = json.loads(run("codex", "app-server", "daemon", "version"))
    emit("versions", **version)
    values = [version.get(k) for k in ("cliVersion", "managedCodexVersion", "appServerVersion")]
    issues = []
    if not all(values) or len(set(values)) != 1:
        issues.append("Installed CLI/managed/daemon versions are unknown or different")
    status, lines = trust.report()
    emit("hookTrust", status=status, detail=lines)
    if status != "ok":
        issues.append("Hook trust is not confirmed")
    with tempfile.TemporaryDirectory(prefix="vibebuddy-codex-schema-") as directory:
        run("codex", "app-server", "generate-json-schema", "--out", directory)
        schema = Path(directory)
        request = json.loads((schema / "ClientRequest.json").read_text())
        methods = {v["properties"]["method"]["enum"][0] for v in request["oneOf"]}
        source = (ROOT / "VibeBuddyMac/Sources/VibeBuddyMacCore/CodexAppServerMonitor.swift").read_text()
        used = set(re.findall(r'client\.request\("([^"]+)"', source))
        missing = sorted(used - methods)
        emit("clientMethods", checked=sorted(used), absent=missing)
        issues.extend("Missing method: " + method for method in missing)
        # Bound the audit to the contracts our approval/steer implementation uses.
        required = {
            "v2/TurnSteerParams.json": {"threadId", "input", "expectedTurnId"},
            "PermissionsRequestApprovalParams.json": {"threadId", "turnId", "itemId", "cwd", "permissions", "startedAtMs"},
        }
        for name, expected in required.items():
            actual = set(json.loads((schema / name).read_text()).get("required", []))
            emit("requiredFields", schema=name, fields=sorted(actual))
            if actual != expected:
                issues.append("Review changed required fields: " + name)
        server = json.loads((schema / "ServerRequest.json").read_text())
        server_methods = sorted(v["properties"]["method"]["enum"][0] for v in server["oneOf"])
        emit("serverRequests", methods=server_methods)
    emit("audit", status="review" if issues else "pass", issues=issues,
         limit="Local contract audit; does not establish upstream latest, event delivery or device acceptance")
    return bool(issues)


def watch(thread, seconds):
    # Validate before touching the daemon. No broad history retrieval.
    import uuid
    uuid.UUID(thread)
    c = trust._Connection(trust.DEFAULT_SOCKET, 1)
    try:
        c.send({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "vibebuddy-source-probe", "version": "1"},
            "capabilities": {"experimentalApi": True}}})
        c.response(1, time.monotonic() + 5)
        c.send({"method": "initialized"})
        c.send({"id": 2, "method": "thread/resume", "params": {"threadId": thread, "excludeTurns": True}})
        try:
            result = c.response(2, time.monotonic() + 5)["thread"]
            emit("subscription", status="subscribed")
        except trust.Unreachable as error:
            if "already has an active writer" not in str(error):
                raise
            emit("subscription", status="unavailable", reason="task belongs to another app-server writer")
            c.send({"id": 3, "method": "thread/read", "params": {"threadId": thread, "includeTurns": False}})
            result = c.response(3, time.monotonic() + 5)["thread"]
        if result["id"] != thread:
            raise RuntimeError("Subscription returned a different task")
        emit("target", thread=thread, source=result.get("source"), socketStatus=result.get("status"))
        rollout = Path(result["path"]) if result.get("path") else None
        offset = rollout.stat().st_size if rollout and rollout.exists() else 0
        tail = ""
        counts = collections.Counter()
        token_path = Path.home() / "Library/Application Support/vibebuddy/token"
        token = token_path.read_text().strip() if token_path.exists() else ""
        previous = None
        last_poll = 0
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            for raw in c._frames():
                msg = json.loads(raw)
                params = msg.get("params") or {}
                if params.get("threadId") != thread:
                    continue
                method = msg.get("method", "")
                if method.startswith("hook/"):
                    hook = params.get("run") or {}
                    emit("hook", method=method, thread=thread, turn=params.get("turnId"),
                         run={k: hook.get(k) for k in ("id", "eventName", "status", "source", "sourcePath", "scope", "executionMode")})
                elif "id" in msg or method in ("serverRequest/resolved", "thread/status/changed", "turn/started", "turn/completed"):
                    emit("appserver", method=method, request=msg.get("id"), thread=thread,
                         turn=params.get("turnId"), status=params.get("status"))
            if time.monotonic() - last_poll > 0.5:
                last_poll = time.monotonic()
                req = urllib.request.Request("http://127.0.0.1:9876/snapshot", headers={"Authorization": "Bearer " + token})
                try:
                    with urllib.request.urlopen(req, timeout=1) as response:
                        snapshot = json.load(response)
                    session = next((s for s in snapshot.get("sessions", []) if s.get("id") == thread), {})
                    card = session.get("pendingApproval") or {}
                    view = {"status": session.get("status"), "card": card.get("id"),
                            "answerable": card.get("answerable"), "tool": card.get("tool"),
                            "observations": session.get("observations")}
                    if view != previous:
                        emit("vibebuddy", thread=thread, **view)
                        previous = view
                except (OSError, ValueError) as error:
                    if previous != "unavailable":
                        emit("vibebuddy", status="unavailable", reason=type(error).__name__)
                        previous = "unavailable"
            if rollout and rollout.exists():
                with rollout.open() as stream:
                    stream.seek(offset)
                    tail += stream.read()
                    offset = stream.tell()
                lines = tail.split("\n")
                tail = lines.pop()
                for line in lines:
                    if not line:
                        continue
                    record = json.loads(line)
                    event = record.get("payload") or {}
                    kind = record.get("type", "unknown")
                    subtype = event.get("type") if isinstance(event, dict) else None
                    counts[(kind, subtype)] += 1
                    emit("rollout", recordType=kind, eventType=subtype)
            try:
                chunk = c.socket.recv(65536)
                if not chunk:
                    raise RuntimeError("Daemon disconnected; evidence window incomplete")
                c.buffer.extend(chunk)
            except socket.timeout:
                pass
        emit("windowComplete", thread=thread, seconds=seconds,
             rolloutCounts=[{"type": k[0], "event": k[1], "count": v} for k, v in counts.items()])
    finally:
        c.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["audit", "watch"])
    parser.add_argument("--thread")
    parser.add_argument("--seconds", type=int, default=180)
    args = parser.parse_args()
    if args.command == "audit":
        raise SystemExit(audit())
    if not args.thread or not 1 <= args.seconds <= 1800:
        parser.error("watch requires --thread and --seconds between 1 and 1800")
    watch(args.thread, args.seconds)
