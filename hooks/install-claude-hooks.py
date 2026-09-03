#!/usr/bin/env python3
"""Install/uninstall vibebuddy hooks in ~/.claude/settings.json.

Fail-open: each hook just POSTs the event JSON to the local daemon and never
blocks Claude Code. Idempotent, reversible, and backs up the original once.

Usage:
    python3 install-claude-hooks.py --dry-run     # show what would be added
    python3 install-claude-hooks.py --install     # back up + write
    python3 install-claude-hooks.py --uninstall   # remove vibebuddy hooks
"""
import json
import os
import shutil
import sys
import tempfile

SETTINGS = os.path.expanduser("~/.claude/settings.json")
BACKUP = os.path.expanduser("~/.claude/settings.json.vibebuddy-backup")
PORT = int(os.environ.get("VIBEBUDDY_PORT", "9876"))
# Use Claude's exec-form command hook (`command` + `args`) so no shell parses the
# status forwarder. The shared script reads the rotating token at runtime and is
# fail-open. MARKER recognizes and removes the older inline-curl install.
MARKER = f"127.0.0.1:{PORT}/hook"
FORWARDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibebuddy-forward.sh")
FORWARDER_MARKER = "vibebuddy-forward.sh"
APPROVAL_HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "approval-hook.sh")
APPROVAL_COMMAND = f'"{APPROVAL_HOOK}"'
APPROVAL_MARKER = "approval-hook.sh"
CAPTURE_HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "capture-terminal.sh")
CAPTURE_MARKER = "capture-terminal.sh"
TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied"}
# High-signal lifecycle events used by current maintained monitors. Deliberately
# omit display/file/config telemetry that adds process churn without changing a
# session's progress or attention state.
EVENTS = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
    "PermissionDenied", "PostToolUse", "PostToolUseFailure", "Notification",
    "PostToolBatch", "Elicitation", "ElicitationResult", "SubagentStart", "SubagentStop",
    "TaskCreated", "TaskCompleted", "PreCompact", "PostCompact",
    "Stop", "StopFailure", "PostModelSwitch", "CwdChanged", "SessionEnd",
]
# Terminal capture runs on SessionStart (catch new sessions) AND UserPromptSubmit
# (re-capture so a session that missed SessionStart — e.g. the hook was added
# mid-session — self-heals on its next prompt; writing the same ref is idempotent).
CAPTURE_EVENTS = ["SessionStart", "UserPromptSubmit"]


def group(event):
    # Status delivery must never sit on Claude's critical path. Permission
    # decisions use the separate opt-in approval hook below and stay synchronous.
    g = {"hooks": [{"type": "command", "command": FORWARDER,
                    "args": ["claude"], "timeout": 5, "async": True}]}
    return {"matcher": "*", **g} if event in TOOL_EVENTS else g


def has_marker(g, marker):
    return isinstance(g, dict) and any(
        marker in h.get("command", "")
        for h in g.get("hooks", []) if isinstance(h, dict)
    )


def has_status_marker(g):
    return has_marker(g, MARKER) or has_marker(g, FORWARDER_MARKER)


def is_vibebuddy(g):
    return has_status_marker(g) or any(
        has_marker(g, marker) for marker in [APPROVAL_MARKER, CAPTURE_MARKER]
    )


def install(data):
    hooks = data.setdefault("hooks", {})
    added = []
    for ev in EVENTS:
        arr = hooks.setdefault(ev, [])
        expected = group(ev)
        owned = [g for g in arr if has_status_marker(g)]
        if owned == [expected]:
            continue
        arr[:] = [g for g in arr if not has_status_marker(g)]
        arr.append(expected)
        added.append(ev)
    for ev in CAPTURE_EVENTS:
        arr = hooks.setdefault(ev, [])
        # The inert `claude` argument is there for Grok's `[compat.claude]`
        # bridge, which imports these hooks and resolves a quoted, argument-less
        # command as a literal path (`~/.claude/"/…/capture-terminal.sh"`,
        # command not found). With an argument the command is shell-parsed by
        # both CLIs; `capture-terminal.sh` reads stdin and the env, never `$1`.
        expected = {"hooks": [{"type": "command", "command": f'"{CAPTURE_HOOK}" claude',
                                "timeout": 5, "async": True}]}
        owned = [g for g in arr if has_marker(g, CAPTURE_MARKER)]
        if owned != [expected]:
            arr[:] = [g for g in arr if not has_marker(g, CAPTURE_MARKER)]
            arr.append(expected)
    return added


def install_approval(data):
    hooks = data.setdefault("hooks", {})
    arr = hooks.setdefault("PreToolUse", [])
    # Drop the fire-and-forget vibebuddy /hook group for PreToolUse; the blocking
    # approval hook subsumes the working-status update via /approval.
    arr[:] = [g for g in arr if not has_status_marker(g)]
    if not any(has_marker(g, APPROVAL_MARKER) for g in arr):
        arr.append({"matcher": "*", "hooks": [{"type": "command", "command": APPROVAL_COMMAND}]})
    return ["PreToolUse(approval)"]


def uninstall(data):
    hooks = data.get("hooks", {})
    removed = []
    for ev in list(hooks.keys()):
        before = len(hooks[ev])
        hooks[ev] = [g for g in hooks[ev] if not is_vibebuddy(g)]
        if len(hooks[ev]) < before:
            removed.append(ev)
        if not hooks[ev]:
            del hooks[ev]
    return removed


def write(data):
    directory = os.path.dirname(SETTINGS)
    os.makedirs(directory, exist_ok=True)
    if os.path.exists(SETTINGS) and not os.path.exists(BACKUP):
        shutil.copy2(SETTINGS, BACKUP)
        print("backup written:", BACKUP)
    encoded = (json.dumps(data, indent=2, ensure_ascii=False) + "\n").encode()
    descriptor, temporary = tempfile.mkstemp(prefix=".settings.json.vibebuddy-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
        os.chmod(temporary, 0o600)
        os.replace(temporary, SETTINGS)
        with open(SETTINGS, "rb") as handle:
            json.load(handle)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--dry-run"
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            data = json.load(f)
        if not isinstance(data, dict) or not isinstance(data.get("hooks", {}), dict):
            raise ValueError("Claude settings root and hooks must be objects")
    else:
        data = {}

    if mode == "--uninstall":
        removed = uninstall(data)
        write(data)
        print("removed vibebuddy hooks from:", removed or "(none)")
        return

    if mode == "--approval":
        install(data)              # ensure base status hooks exist
        added = install_approval(data)
        write(data)
        print("installed vibebuddy approval hook:", added)
        return

    added = install(data)
    if mode == "--dry-run":
        print("would add vibebuddy hooks for:", added or "(already installed)")
        print("status events:", ", ".join(EVENTS))
    elif mode == "--install":
        write(data)
        print("installed vibebuddy hooks for:", added or "(already installed)")
    else:
        print("unknown mode:", mode)
        sys.exit(2)


if __name__ == "__main__":
    main()
