#!/usr/bin/env python3
"""Report whether Codex is actually running VibeBuddy's hooks.

Codex only executes a hook whose trust status is `trusted` or `managed`
(`codex-rs/hooks/src/engine/discovery.rs`: the handler is added only when
``enabled && (bypass_hook_trust || matches!(trust_status, Managed | Trusted))``).
A hook whose normalized identity — event, matcher, command, timeout, async —
no longer matches the `trusted_hash` recorded in `~/.codex/config.toml` becomes
`modified`, and a brand new one is `untrusted`. Neither runs, and neither is
reported as an error anywhere: writing hooks.json is not enough.

The only source of truth for that state is the running app-server daemon's
`hooks/list`. This module asks it over the shared control socket and reports
what it says. It is read-only: it calls `initialize` and `hooks/list`, then
closes. It never writes a `trusted_hash` — trusting a hook is the user's
security decision, made in Codex's own `/hooks` UI.

    python3 codex_hook_trust.py            # human-readable report
    python3 codex_hook_trust.py --json     # machine-readable

Exit status: 0 every hook is running, 1 some are not, 2 the daemon could not be
reached (no verdict, not a failure).
"""
import base64
import json
import os
import socket
import struct
import sys
import time

DEFAULT_SOCKET = os.path.expanduser(
    "~/.codex/app-server-control/app-server-control.sock")
# The scripts install-codex-hooks.py writes into hooks.json.
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
            "Run install-codex-hooks.py --install, then start a fresh Codex session.",
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


def main():
    as_json = "--json" in sys.argv[1:]
    if as_json:
        try:
            hooks = ours(fetch())
        except Unreachable as error:
            print(json.dumps({"status": "unreachable", "reason": str(error)}))
            return 2
        stopped = blocked(hooks)
        print(json.dumps({
            "status": "ok" if hooks and not stopped else "blocked",
            "hooks": [{"event": h.get("eventName"), "trustStatus": h.get("trustStatus"),
                       "enabled": h.get("enabled"), "async": h.get("async"),
                       "timeoutSec": h.get("timeoutSec"), "key": h.get("key")}
                      for h in sorted(hooks, key=describe)],
        }, indent=2))
        return 0 if hooks and not stopped else 1
    status, lines = report()
    for line in lines:
        print(line)
    return {"ok": 0, "blocked": 1, "unreachable": 2}[status]


if __name__ == "__main__":
    sys.exit(main())
