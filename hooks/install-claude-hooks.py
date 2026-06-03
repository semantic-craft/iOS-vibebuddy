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

SETTINGS = os.path.expanduser("~/.claude/settings.json")
BACKUP = os.path.expanduser("~/.claude/settings.json.vibebuddy-backup")
PORT = int(os.environ.get("VIBEBUDDY_PORT", "9876"))
COMMAND = (
    f"curl -sS --max-time 3 -X POST --data-binary @- "
    f"http://127.0.0.1:{PORT}/hook 2>/dev/null || true"
)
MARKER = f"127.0.0.1:{PORT}/hook"
TOOL_EVENTS = {"PreToolUse", "PostToolUse"}
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse",
          "PostToolUse", "Notification", "Stop"]


def group(event):
    g = {"hooks": [{"type": "command", "command": COMMAND}]}
    return {"matcher": "*", **g} if event in TOOL_EVENTS else g


def is_vibebuddy(g):
    return isinstance(g, dict) and any(
        MARKER in h.get("command", "") for h in g.get("hooks", []) if isinstance(h, dict)
    )


def install(data):
    hooks = data.setdefault("hooks", {})
    added = []
    for ev in EVENTS:
        arr = hooks.setdefault(ev, [])
        if any(is_vibebuddy(g) for g in arr):
            continue
        arr.append(group(ev))
        added.append(ev)
    return added


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
    if not os.path.exists(BACKUP):
        shutil.copy2(SETTINGS, BACKUP)
        print("backup written:", BACKUP)
    with open(SETTINGS, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--dry-run"
    with open(SETTINGS) as f:
        data = json.load(f)

    if mode == "--uninstall":
        removed = uninstall(data)
        write(data)
        print("removed vibebuddy hooks from:", removed or "(none)")
        return

    added = install(data)
    if mode == "--dry-run":
        print("would add vibebuddy hooks for:", added or "(already installed)")
        print("--- the only thing added (no secrets) ---")
        print(json.dumps({"hooks": {ev: data["hooks"][ev] for ev in EVENTS}}, indent=2))
    elif mode == "--install":
        write(data)
        print("installed vibebuddy hooks for:", added or "(already installed)")
    else:
        print("unknown mode:", mode)
        sys.exit(2)


if __name__ == "__main__":
    main()
