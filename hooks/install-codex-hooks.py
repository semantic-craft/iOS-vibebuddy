#!/usr/bin/env python3
"""Install/uninstall VibeBuddy lifecycle hooks in ~/.codex/hooks.json.

The Codex ``notify`` command is deliberately untouched: it may already belong
to Codex Computer Use or another notifier. Lifecycle progress belongs in
``hooks.json``, where multiple consumers can coexist.
"""
import json
import os
import shlex
import shutil
import sys
import tempfile

HOOKS = os.path.expanduser("~/.codex/hooks.json")
BACKUP = os.path.expanduser("~/.codex/hooks.json.vibebuddy-backup")
FORWARDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibebuddy-forward.sh")
COMMAND = f'"{FORWARDER}" codex'
EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "PreCompact",
    "PostCompact",
    "SubagentStart",
    "SubagentStop",
    "Stop",
    "Interrupt",
    "SessionEnd",
]
# Terminal capture (jump-to-terminal) runs as a second, independent hook group on
# SessionStart (catch new sessions) and UserPromptSubmit (self-heal a session that
# missed SessionStart) — see capture-terminal.sh and install-claude-hooks.py's
# CAPTURE_EVENTS for the matching Claude wiring. The re-capture is *not*
# idempotent: it skips the Ghostty AppleScript probe, which is only correct while
# the surface is focused. The Mac therefore merges each ref into the stored one
# field by field, so a later capture can add and update but never erase.
CAPTURE_HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "capture-terminal.sh")
CAPTURE_MARKER = "capture-terminal.sh"
CAPTURE_COMMAND = f'"{CAPTURE_HOOK}"'
CAPTURE_EVENTS = ["SessionStart", "UserPromptSubmit"]


def load():
    if not os.path.exists(HOOKS):
        return {}
    with open(HOOKS) as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("Codex hooks.json root must be an object")
    configured = value.get("hooks", {})
    if not isinstance(configured, dict):
        raise ValueError("Codex hooks.json 'hooks' must be an object")
    for event, groups in configured.items():
        if not isinstance(groups, list):
            raise ValueError(f"Codex hook event {event!r} must contain an array")
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError(f"Codex hook event {event!r} contains an invalid group")
            if not all(isinstance(hook, dict) for hook in group["hooks"]):
                raise ValueError(f"Codex hook event {event!r} contains an invalid command")
    return value


def is_forwarder(hook):
    if not isinstance(hook, dict) or not isinstance(hook.get("command"), str):
        return False
    try:
        argv = shlex.split(hook["command"])
    except ValueError:
        return False
    return (len(argv) == 2 and os.path.basename(argv[0]) == "vibebuddy-forward.sh"
            and argv[1] == "codex")


def is_capture(hook):
    if not isinstance(hook, dict) or not isinstance(hook.get("command"), str):
        return False
    try:
        argv = shlex.split(hook["command"])
    except ValueError:
        return False
    return len(argv) == 1 and os.path.basename(argv[0]) == CAPTURE_MARKER


def is_vibebuddy(hook):
    return is_forwarder(hook) or is_capture(hook)


def without_vibebuddy(groups):
    cleaned = []
    for group in groups if isinstance(groups, list) else []:
        if not isinstance(group, dict):
            continue
        hooks = [hook for hook in group.get("hooks", []) if not is_vibebuddy(hook)]
        if hooks:
            cleaned.append({**group, "hooks": hooks})
    return cleaned


def install(root):
    hooks = root.get("hooks") if isinstance(root.get("hooks"), dict) else {}
    for event in list(hooks):
        hooks[event] = without_vibebuddy(hooks[event])
        if not hooks[event]:
            del hooks[event]
    for event in EVENTS:
        command = {
            "type": "command",
            "command": COMMAND,
            "timeout": 3,
        }
        # Released Codex builds currently skip command hooks carrying
        # `async: true`; SessionEnd is synchronous by design as well. Keep all
        # handlers synchronous and bounded, while the forwarder caps its local
        # HTTP request at one second.
        hooks.setdefault(event, []).append({"hooks": [command]})
    for event in CAPTURE_EVENTS:
        capture = {
            "type": "command",
            "command": CAPTURE_COMMAND,
            "timeout": 5,
        }
        # Same released-Codex constraint as above: no `async: true`.
        hooks.setdefault(event, []).append({"hooks": [capture]})
    root["hooks"] = hooks
    return root


def uninstall(root):
    hooks = root.get("hooks") if isinstance(root.get("hooks"), dict) else {}
    for event in list(hooks):
        hooks[event] = without_vibebuddy(hooks[event])
        if not hooks[event]:
            del hooks[event]
    if hooks:
        root["hooks"] = hooks
    else:
        root.pop("hooks", None)
    return root


def encoded(root):
    return (json.dumps(root, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def write(data):
    directory = os.path.dirname(HOOKS)
    os.makedirs(directory, exist_ok=True)
    if os.path.exists(HOOKS) and not os.path.exists(BACKUP):
        shutil.copy2(HOOKS, BACKUP)
        print("backup written:", BACKUP)
    descriptor, temporary = tempfile.mkstemp(prefix=".hooks.json.vibebuddy-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, HOOKS)
        with open(HOOKS, "rb") as handle:
            json.load(handle)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--dry-run"
    if mode not in {"--dry-run", "--install", "--uninstall"}:
        print("unknown mode:", mode)
        sys.exit(2)
    try:
        root = load()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print("cannot safely update Codex hooks.json:", error, file=sys.stderr)
        sys.exit(1)

    before = encoded(root)
    updated = uninstall(root) if mode == "--uninstall" else install(root)
    after = encoded(updated)
    changed = before != after

    if mode == "--dry-run":
        print("would install VibeBuddy Codex lifecycle hooks"
              if changed else "VibeBuddy Codex lifecycle hooks already installed")
        print("Codex notify remains untouched")
    elif not changed:
        print("VibeBuddy Codex lifecycle hooks already in requested state — no-op")
    else:
        write(after)
        action = "removed" if mode == "--uninstall" else "installed"
        print(f"{action} VibeBuddy Codex lifecycle hooks; preserved all other hooks and notify")
        if mode == "--install":
            print("next: start a fresh Codex session, run /hooks, and trust the VibeBuddy entries")


if __name__ == "__main__":
    main()
