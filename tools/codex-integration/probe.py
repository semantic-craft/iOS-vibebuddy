#!/usr/bin/env python3
"""Read-only Codex version/contract audit and thread-scoped source evidence.

No hook/config writes, no approval responses, no turn creation. The watch command
subscribes to a supplied task and prints metadata only, never prompts/tool output.
"""
import argparse
import collections
import json
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]

# --- Codex app-server control socket (read-only) ------------------------------
# The shipped check lives in Swift (`CodexHookTrustProbe`, printed by
# `vibebuddyd hooks status`); this developer probe keeps its own minimal client.
import base64
import os
import struct

DEFAULT_SOCKET = os.path.expanduser(
    "~/.codex/app-server-control/app-server-control.sock")
# The scripts VibeBuddy's installer writes into hooks.json.
MARKERS = ("vibebuddy-forward.sh", "approval-hook.sh", "capture-terminal.sh")
# `HookTrustStatus` values that let a hook run; `modified` and `untrusted` don't.
RUNNING = {"trusted", "managed"}
CLIENT = {"name": "vibebuddy-hook-trust", "version": "1"}


class Unreachable(Exception):
    """No daemon answered, so there is no verdict to report."""


class _Connection:
    """A minimal RFC 6455 client over a unix socket, enough for one probe.

    The daemon speaks WebSocket on its control socket, so a plain JSON-lines
    write does not reach it. Only text frames are collected; ping, pong and
    close frames are read and dropped, which is sufficient for a connection
    that lives for a second or two.
    """

    def __init__(self, path, timeout):
        self.buffer = bytearray()
        try:
            self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.socket.settimeout(timeout)
            self.socket.connect(path)
        except OSError as error:
            raise Unreachable(f"{path}: {error}") from error
        self._handshake()

    def _handshake(self):
        key = base64.b64encode(os.urandom(16)).decode()
        self.socket.sendall(
            "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            .encode())
        head = bytearray()
        while b"\r\n\r\n" not in head:
            try:
                chunk = self.socket.recv(4096)
            except OSError as error:
                raise Unreachable(f"handshake: {error}") from error
            if not chunk:
                raise Unreachable("handshake: connection closed")
            head.extend(chunk)
        header, _, rest = bytes(head).partition(b"\r\n\r\n")
        status = header.split(b"\r\n", 1)[0].decode(errors="replace")
        if "101" not in status:
            raise Unreachable(f"handshake rejected: {status}")
        self.buffer.extend(rest)

    def send(self, message):
        payload = json.dumps(message).encode()
        mask = os.urandom(4)
        size = len(payload)
        if size < 126:
            header = struct.pack("!BB", 0x81, 0x80 | size)
        elif size < 1 << 16:
            header = struct.pack("!BBH", 0x81, 0x80 | 126, size)
        else:
            header = struct.pack("!BBQ", 0x81, 0x80 | 127, size)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.socket.sendall(header + mask + masked)

    def _frames(self):
        """Every complete text frame currently buffered."""
        while True:
            if len(self.buffer) < 2:
                return
            opcode = self.buffer[0] & 0x0F
            size = self.buffer[1] & 0x7F
            offset = 2
            if size == 126:
                if len(self.buffer) < 4:
                    return
                size = struct.unpack("!H", self.buffer[2:4])[0]
                offset = 4
            elif size == 127:
                if len(self.buffer) < 10:
                    return
                size = struct.unpack("!Q", self.buffer[2:10])[0]
                offset = 10
            if len(self.buffer) < offset + size:
                return
            payload = bytes(self.buffer[offset:offset + size])
            del self.buffer[:offset + size]
            if opcode == 1:
                yield payload.decode(errors="replace")

    def response(self, request_id, deadline):
        """The result of one request, ignoring notifications that arrive first."""
        while time.monotonic() < deadline:
            for text in self._frames():
                try:
                    message = json.loads(text)
                except ValueError:
                    continue
                if message.get("id") != request_id:
                    continue
                if "error" in message:
                    raise Unreachable(f"hooks/list: {message['error']}")
                return message.get("result") or {}
            try:
                chunk = self.socket.recv(65536)
            except socket.timeout:
                continue
            except OSError as error:
                raise Unreachable(str(error)) from error
            if not chunk:
                raise Unreachable("connection closed")
            self.buffer.extend(chunk)
        raise Unreachable("timed out waiting for the daemon")

    def close(self):
        try:
            self.socket.close()
        except OSError:
            pass


def fetch(socket_path=DEFAULT_SOCKET, timeout=5.0):
    """Every hook the daemon knows about, flattened across working directories.

    Raises `Unreachable` when no daemon answers — that is the ordinary state on
    a machine where Codex has not been started, not an installation problem.
    """
    connection = _Connection(socket_path, timeout)
    deadline = time.monotonic() + timeout
    try:
        connection.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"clientInfo": CLIENT}})
        connection.response(1, deadline)
        connection.send({"jsonrpc": "2.0", "method": "initialized"})
        connection.send({"jsonrpc": "2.0", "id": 2, "method": "hooks/list", "params": {}})
        result = connection.response(2, deadline)
    finally:
        connection.close()
    hooks = []
    for entry in result.get("data") or []:
        for hook in entry.get("hooks") or []:
            if isinstance(hook, dict):
                hooks.append(hook)
    return hooks


def ours(hooks):
    """The subset this repo's installer wrote, newest state per hook key."""
    seen = {}
    for hook in hooks:
        command = hook.get("command")
        if not isinstance(command, str) or not any(m in command for m in MARKERS):
            continue
        seen.setdefault(hook.get("key") or id(hook), hook)
    return list(seen.values())


def blocked(hooks):
    """Ours that Codex will not run, and why."""
    return [hook for hook in hooks
            if not hook.get("enabled") or hook.get("trustStatus") not in RUNNING]


def describe(hook):
    reason = "disabled" if not hook.get("enabled") else hook.get("trustStatus")
    return f"{hook.get('eventName', '?')}: {reason}"


def report(socket_path=DEFAULT_SOCKET, timeout=5.0):
    """`(status, lines)` where status is "ok", "blocked" or "unreachable"."""
    try:
        hooks = ours(fetch(socket_path, timeout))
    except Unreachable as error:
        return "unreachable", [
            f"could not ask Codex whether its hooks are trusted ({error}).",
            "Start Codex, then re-run this check.",
        ]
    if not hooks:
        return "blocked", [
            "Codex reports no VibeBuddy hooks at all.",
            "Run vibebuddyd hooks install --agent codex (or Settings > Install), then start a fresh Codex session.",
        ]
    stopped = blocked(hooks)
    if not stopped:
        return "ok", [f"Codex is running all {len(hooks)} VibeBuddy hooks."]
    lines = [
        f"Codex is skipping {len(stopped)} of {len(hooks)} VibeBuddy hooks; "
        "it does not report this as an error:",
    ]
    lines += [f"  {describe(hook)}" for hook in sorted(stopped, key=describe)]
    lines += [
        "A hook Codex has not trusted since its last change never runs.",
        "Fix: start a fresh Codex session, run /hooks, and trust the VibeBuddy entries.",
    ]
    return "blocked", lines




class _Trust:
    """Namespace kept so the call sites below read as before."""
    Unreachable = Unreachable
    _Connection = _Connection
    DEFAULT_SOCKET = DEFAULT_SOCKET
    report = staticmethod(report)


trust = _Trust


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
