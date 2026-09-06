#!/usr/bin/env python3
"""Install/uninstall VibeBuddy lifecycle hooks in ~/.codex/hooks.json.

    --dry-run    preview (default)
    --install    status hooks (plus terminal capture); keeps an existing approval gate
    --approval   --install, with the blocking phone-approval gate on PermissionRequest
    --uninstall  remove every VibeBuddy entry

The Codex ``notify`` command is deliberately untouched: it may already belong
to Codex Computer Use or another notifier. Lifecycle progress belongs in
``hooks.json``, where multiple consumers can coexist.
"""
import json
import os
import re
import shlex
import shutil
import sys
import tempfile

HOOKS = os.path.expanduser("~/.codex/hooks.json")
BACKUP = os.path.expanduser("~/.codex/hooks.json.vibebuddy-backup")
FORWARDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibebuddy-forward.sh")
COMMAND = f'"{FORWARDER}" codex'
# Remote approval (--approval): Codex fires PermissionRequest only when it would
# prompt, and honours the hook's `decision.behavior` there — so the blocking gate
# replaces the fire-and-forget PermissionRequest group and nothing else. The
# daemon answers within 25s; 30s leaves the hook's own curl cap (30s) room.
APPROVAL_HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "approval-hook.sh")
APPROVAL_COMMAND = f'"{APPROVAL_HOOK}" codex'
APPROVAL_EVENT = "PermissionRequest"
APPROVAL_TIMEOUT = 30
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


def is_approval(hook):
    if not isinstance(hook, dict) or not isinstance(hook.get("command"), str):
        return False
    try:
        argv = shlex.split(hook["command"])
    except ValueError:
        return False
    return (len(argv) == 2 and os.path.basename(argv[0]) == "approval-hook.sh"
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
    return is_forwarder(hook) or is_capture(hook) or is_approval(hook)


def has_approval(root):
    hooks = root.get("hooks") if isinstance(root.get("hooks"), dict) else {}
    return any(is_approval(hook)
               for group in hooks.get(APPROVAL_EVENT, []) if isinstance(group, dict)
               for hook in group.get("hooks", []))


def without_vibebuddy(groups):
    cleaned = []
    for group in groups if isinstance(groups, list) else []:
        if not isinstance(group, dict):
            continue
        hooks = [hook for hook in group.get("hooks", []) if not is_vibebuddy(hook)]
        if hooks:
            cleaned.append({**group, "hooks": hooks})
    return cleaned


def install(root, approval=False):
    # A plain re-install (the Mac app's Repair button) must not silently drop a
    # gate the user opted into, so an existing gate is carried forward.
    approval = approval or has_approval(root)
    hooks = root.get("hooks") if isinstance(root.get("hooks"), dict) else {}
    for event in list(hooks):
        hooks[event] = without_vibebuddy(hooks[event])
        if not hooks[event]:
            del hooks[event]
    for event in EVENTS:
        if approval and event == APPROVAL_EVENT:
            command = {
                "type": "command",
                "command": APPROVAL_COMMAND,
                "timeout": APPROVAL_TIMEOUT,
            }
        else:
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


def feature_key_path(text):
    # Bare and simply quoted path components; a quoted literal containing a dot
    # is not the equivalent dotted path and deliberately does not match.
    result = []
    for part in text.split("."):
        token = part.strip()
        if token[:1] in {"'", '"'} and len(token) >= 2 and token[-1] == token[0]:
            token = token[1:-1]
        if not re.fullmatch(r"[A-Za-z0-9_-]+", token):
            return None
        result.append(token)
    return result


def hooks_feature_disabled():
    # Only the user-level file: our hooks live there. Profile and project
    # overrides are outside this diagnostic's scope. A minimal scalar scanner,
    # not a TOML parser. Skip multiline strings so example keys are not settings.
    try:
        with open(os.path.expanduser("~/.codex/config.toml"), "rb") as handle:
            data = handle.read((1 << 20) + 1)
            if len(data) > 1 << 20:
                return False
            text = data.decode("utf-8")
    except (OSError, UnicodeError):
        return False
    table = []
    multiline = None
    values = {}
    for raw in text.splitlines():
        if multiline is not None:
            if multiline in raw:
                multiline = None
            continue
        line = raw.split("#", 1)[0].strip()
        delimiters = [(line.find(mark), mark) for mark in ['"""', "'''"] if mark in line]
        if delimiters:
            index, mark = min(delimiters)
            if mark not in line[index + 3:]:
                multiline = mark
            continue
        if line.startswith("["):
            table = feature_key_path(line[1:-1]) if line.endswith("]") else None
            continue
        if table is None or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        path = feature_key_path(key)
        if path is not None:
            path = table + path
            if path in [["features", "hooks"], ["features", "codex_hooks"]] and value in {"true", "false"}:
                values[path[-1]] = value == "true"
    # The canonical key wins over its deprecated alias.
    return values.get("hooks", values.get("codex_hooks")) is False


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--dry-run"
    if mode not in {"--dry-run", "--install", "--uninstall", "--approval"}:
        print("unknown mode:", mode)
        sys.exit(2)
    try:
        root = load()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print("cannot safely update Codex hooks.json:", error, file=sys.stderr)
        sys.exit(1)

    before = encoded(root)
    if mode == "--uninstall":
        updated = uninstall(root)
    else:
        updated = install(root, approval=(mode == "--approval"))
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
        if mode == "--approval":
            print("installed the blocking phone-approval gate on PermissionRequest")
        if mode in {"--install", "--approval"}:
            print("next: start a fresh Codex session, run /hooks, and trust the VibeBuddy entries")

    if mode != "--uninstall" and hooks_feature_disabled():
        print("Hooks feature disabled: run codex features enable hooks, then start a fresh Codex session.")


if __name__ == "__main__":
    main()
