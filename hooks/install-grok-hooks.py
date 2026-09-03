#!/usr/bin/env python3
"""Install/uninstall vibebuddy hooks for Grok Build.

Grok discovers standalone hook files from `~/.grok/hooks/*.json`. We write a
dedicated `vibebuddy.json` whose command hooks pipe each lifecycle event to the
shared forwarder (`hooks/vibebuddy-forward.sh grok`); the daemon's source-aware
HookDecoder runs the grok camelCase decoder. Grok's `http` hooks reject loopback
(SSRF guard), so **command** hooks are required. The forwarder is fail-open and
exits 0 with no stdout, so PreToolUse never blocks grok.

Do NOT rely on Grok's `[compat.claude]` auto-bridge of `~/.claude/settings.json`:
it forwards the wrong (Claude) shape and omits `?agent=grok`.

Idempotent (re-run rewrites the same file), reversible (`--uninstall` deletes it;
a pre-existing non-vibebuddy file is backed up once).

Usage:
    python3 install-grok-hooks.py --dry-run
    python3 install-grok-hooks.py --install
    python3 install-grok-hooks.py --uninstall
"""
import json
import os
import shutil
import sys

HOOKS_DIR = os.path.expanduser("~/.grok/hooks")
TARGET = os.path.join(HOOKS_DIR, "vibebuddy.json")
BACKUP = TARGET + ".vibebuddy-backup"
FORWARDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibebuddy-forward.sh")
COMMAND = f'"{FORWARDER}" grok'
MARKER = "vibebuddy-forward.sh"

# Terminal capture (jump-to-terminal) rides along as a second hook group on
# SessionStart and UserPromptSubmit — see capture-terminal.sh. Grok's payload
# uses camelCase `sessionId`; the script already handles that key. The
# UserPromptSubmit re-capture reports less than the first one (no Ghostty probe),
# so the Mac merges refs field by field rather than replacing them.
CAPTURE_HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "capture-terminal.sh")
CAPTURE_COMMAND = f'"{CAPTURE_HOOK}"'
CAPTURE_MARKER = "capture-terminal.sh"
CAPTURE_EVENTS = ["SessionStart", "UserPromptSubmit"]

# Passive events report status; tool events (omitted matcher → match every tool)
# carry the working / stuck cues. PostToolUseFailure → the grok decoder flags it.
# NB: no `Notification` — grok's notification event is hook-execution telemetry
# (it echoes which hooks ran), not a user-attention signal, so we neither forward
# nor decode it (see GrokParser).
PASSIVE_EVENTS = ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]
TOOL_EVENTS = ["PreToolUse", "PostToolUse", "PostToolUseFailure"]


def group():
    return {"hooks": [{"type": "command", "command": COMMAND, "timeout": 5}]}


def capture_group():
    return {"hooks": [{"type": "command", "command": CAPTURE_COMMAND, "timeout": 5}]}


def build():
    hooks = {ev: [group()] for ev in PASSIVE_EVENTS + TOOL_EVENTS}
    for ev in CAPTURE_EVENTS:
        hooks[ev].append(capture_group())
    return {"hooks": hooks}


def is_ours(path):
    try:
        with open(path) as f:
            return MARKER in f.read()
    except OSError:
        return False


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--dry-run"
    payload = build()

    if mode == "--dry-run":
        print("would write:", TARGET)
        print(json.dumps(payload, indent=2))
        return

    if mode == "--install":
        os.makedirs(HOOKS_DIR, exist_ok=True)
        # Back up a foreign file once; our own file is just overwritten.
        if os.path.exists(TARGET) and not is_ours(TARGET) and not os.path.exists(BACKUP):
            shutil.copy2(TARGET, BACKUP)
            print("backup written:", BACKUP)
        with open(TARGET, "w") as f:
            json.dump(payload, f, indent=2)
            f.write("\n")
        print("installed vibebuddy grok hooks:", TARGET)
        print("reload in grok: press Ctrl+L → Hooks tab → 'l', or restart the session.")
        return

    if mode == "--uninstall":
        if os.path.exists(TARGET) and is_ours(TARGET):
            os.remove(TARGET)
            print("removed:", TARGET)
            if os.path.exists(BACKUP):
                shutil.move(BACKUP, TARGET)
                print("restored backup:", TARGET)
        else:
            print("nothing to remove (not installed by vibebuddy)")
        return

    print("unknown mode:", mode)
    sys.exit(2)


if __name__ == "__main__":
    main()
