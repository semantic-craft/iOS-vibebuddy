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
import re
import shutil
import subprocess
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
# Remote approval (--approval) gates PermissionRequest: Claude fires it only when
# it would stop and ask (a prompt in default mode, an uncertain classifier in
# auto mode), and honours the hook's `decision.behavior` there. Gating every
# PreToolUse instead — the original design, from before this event existed —
# held every tool call for the phone; an old gate found there is migrated.
APPROVAL_EVENT = "PermissionRequest"
LEGACY_APPROVAL_EVENT = "PreToolUse"
# Claude Code validates the `decision` reply on PermissionRequest from 2.1.257;
# an older CLI waits silently on it, so the gate stays on PreToolUse there.
MIN_PERMISSION_REQUEST_VERSION = (2, 1, 257)
APPROVAL_TIMEOUT = 30   # the daemon answers within 25s; the hook's curl caps at 30s
CAPTURE_HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "capture-terminal.sh")
CAPTURE_MARKER = "capture-terminal.sh"
# Status line forwarding: Claude runs one `statusLine.command` per event with
# its session JSON on stdin. The wrapper copies it to the daemon and then runs
# whatever command was configured before, so the terminal display is unchanged.
# The original object is kept beside the daemon token for --uninstall; the bare
# command also goes into a plain file the wrapper can `cat` without parsing.
STATUSLINE_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibebuddy-statusline.sh")
STATUSLINE_MARKER = "vibebuddy-statusline.sh"
SUPPORT_DIR = os.environ.get("VIBEBUDDY_SUPPORT_DIR") or os.path.expanduser(
    "~/Library/Application Support/vibebuddy")
STATUSLINE_ORIGINAL = os.path.join(SUPPORT_DIR, "statusline-original.json")
STATUSLINE_ORIGINAL_CMD = os.path.join(SUPPORT_DIR, "statusline-original.cmd")
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
# mid-session — self-heals on its next prompt). The re-capture skips the Ghostty
# AppleScript probe, so it is not idempotent; the Mac merges each ref into the
# stored one field by field, keeping what a later capture couldn't see.
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


def is_statusline_wrapper(value):
    return isinstance(value, dict) and STATUSLINE_MARKER in str(value.get("command", ""))


def install_statusline(data):
    """Wrap the user's status line (or install ours when there is none).

    Idempotent: a settings file that already names the wrapper is left alone,
    and the saved original is never overwritten by the wrapper itself.
    """
    existing = data.get("statusLine")
    if is_statusline_wrapper(existing):
        return False
    os.makedirs(SUPPORT_DIR, exist_ok=True)
    os.chmod(SUPPORT_DIR, 0o700)
    original = existing if isinstance(existing, dict) else None
    with open(STATUSLINE_ORIGINAL, "w") as handle:
        json.dump({"statusLine": original}, handle)
    os.chmod(STATUSLINE_ORIGINAL, 0o600)
    command = ""
    if original and original.get("type", "command") == "command":
        command = str(original.get("command", "") or "")
    with open(STATUSLINE_ORIGINAL_CMD, "w") as handle:
        handle.write(command)
    os.chmod(STATUSLINE_ORIGINAL_CMD, 0o600)
    wrapper = dict(original) if original else {}
    wrapper["type"] = "command"
    wrapper["command"] = f'"{STATUSLINE_SCRIPT}"'
    data["statusLine"] = wrapper
    return True


def uninstall_statusline(data):
    """Put back whatever status line was there before the wrapper."""
    if not is_statusline_wrapper(data.get("statusLine")):
        return False
    original = None
    if os.path.exists(STATUSLINE_ORIGINAL):
        try:
            with open(STATUSLINE_ORIGINAL) as handle:
                original = json.load(handle).get("statusLine")
        except (OSError, ValueError):
            original = None
    if isinstance(original, dict):
        data["statusLine"] = original
    else:
        data.pop("statusLine", None)
    for path in (STATUSLINE_ORIGINAL, STATUSLINE_ORIGINAL_CMD):
        if os.path.exists(path):
            os.unlink(path)
    return True


def claude_version():
    """The installed Claude Code version as a tuple, or None when unknown.

    `VIBEBUDDY_CLAUDE_VERSION` overrides the probe (tests, air-gapped installs).
    """
    raw = os.environ.get("VIBEBUDDY_CLAUDE_VERSION")
    if raw is None:
        try:
            raw = subprocess.run(["claude", "--version"], capture_output=True,
                                 text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            return None
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", raw or "")
    return tuple(int(part) for part in match.groups()) if match else None


def approval_event(version=None):
    """Where the blocking gate goes for this CLI. Unknown version → the
    current contract (nothing runs at all without a CLI to probe)."""
    if version is not None and version < MIN_PERMISSION_REQUEST_VERSION:
        return LEGACY_APPROVAL_EVENT
    return APPROVAL_EVENT


def has_approval(data):
    hooks = data.get("hooks", {}) if isinstance(data.get("hooks", {}), dict) else {}
    return any(has_marker(g, APPROVAL_MARKER) for arr in hooks.values() for g in arr)


def install_approval(data, version=None):
    hooks = data.setdefault("hooks", {})
    event = approval_event(version)
    # The gate lives on exactly one event: retire it everywhere else (a legacy
    # PreToolUse gate on a modern CLI, or a PermissionRequest gate after a
    # downgrade). install() has already restored the asynchronous status
    # forwarder on whichever event is being vacated.
    for ev in list(hooks):
        if ev != event:
            hooks[ev] = [g for g in hooks[ev] if not has_marker(g, APPROVAL_MARKER)]
            if not hooks[ev]:
                del hooks[ev]
    arr = hooks.setdefault(event, [])
    # The blocking gate replaces the fire-and-forget status group on this one
    # event; the daemon still learns of the wait from the gate itself.
    arr[:] = [g for g in arr if not has_status_marker(g)]
    expected = {"matcher": "*", "hooks": [{"type": "command", "command": APPROVAL_COMMAND,
                                            "timeout": APPROVAL_TIMEOUT}]}
    owned = [g for g in arr if has_marker(g, APPROVAL_MARKER)]
    if owned != [expected]:
        arr[:] = [g for g in arr if not has_marker(g, APPROVAL_MARKER)]
        arr.append(expected)
    if event == LEGACY_APPROVAL_EVENT:
        shown = ".".join(str(part) for part in version)
        wanted = ".".join(str(part) for part in MIN_PERMISSION_REQUEST_VERSION)
        print(f"warning: Claude Code {shown} is older than {wanted}; the approval gate "
              f"stays on PreToolUse, so every tool call the daemon cannot match to a "
              f"rule waits for the phone. Update Claude Code and run --install again.")
    return [f"{event}(approval)"]


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
        if uninstall_statusline(data):
            removed.append("statusLine")
        write(data)
        print("removed vibebuddy hooks from:", removed or "(none)")
        return

    if mode == "--approval":
        install(data)              # ensure base status hooks exist
        install_statusline(data)
        added = install_approval(data, claude_version())
        write(data)
        print("installed vibebuddy approval hook:", added)
        return

    added = install(data)
    if mode == "--install" and install_statusline(data):
        added.append("statusLine")
    if has_approval(data):
        # A plain re-install (the Mac app's Repair button) keeps — and, for an
        # old PreToolUse gate on a current CLI, migrates — the approval gate the
        # user opted into.
        added += install_approval(data, claude_version())
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
