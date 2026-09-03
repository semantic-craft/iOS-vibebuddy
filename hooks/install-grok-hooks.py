#!/usr/bin/env python3
"""Install/uninstall vibebuddy hooks for Grok Build (1.0.13).

Grok discovers standalone hook files from `~/.grok/hooks/*.json`. We write a
dedicated `vibebuddy.json` whose command hooks pipe each lifecycle event to the
shared forwarder (`hooks/vibebuddy-forward.sh grok`); the daemon's source-aware
HookDecoder runs the grok camelCase decoder. Grok's `http` hooks reject loopback
(SSRF guard), so **command** hooks are required. The forwarder is fail-open and
exits 0 with no stdout, so neither the PreToolUse gate nor the Stop gate blocks.

Event set (grok's own names; the decoder maps them to the shared HookEvent):
  - lifecycle: SessionStart, SessionEnd
  - turn:      UserPromptSubmit, Stop, StopFailure, StopCancelled
  - tool:      PreToolUse, PostToolUse, PostToolUseFailure
  - attention: Notification (permission_prompt waits, idle_prompt backstop)
  - topology:  SubagentStart, SubagentStop
`Stop` and `SubagentStop` are gates, so their handler must exit 0 fast; the
forwarder caps its local POST well inside the 5 s timeout we set.

`--approval` additionally routes PreToolUse through the blocking
`hooks/approval-hook.sh grok`, which asks the phone and answers grok's
permission gate. It replaces (not joins) the fire-and-forget PreToolUse group,
and a later plain `--install` keeps it (only `--uninstall` removes it).
Phone answers are only authoritative when grok runs with
`[ui] permission_mode = "always-approve"`; in `default` mode an `allow` decision
merely means "not blocked" and grok still shows its own TUI prompt.

Do NOT rely on Grok's `[compat.claude]` auto-bridge of `~/.claude/settings.json`:
it forwards the wrong (Claude) shape and omits `?agent=grok`.

Idempotent (re-run rewrites the same file), reversible (`--uninstall` deletes it;
a pre-existing non-vibebuddy file is backed up once).

Usage:
    python3 install-grok-hooks.py --dry-run
    python3 install-grok-hooks.py --install
    python3 install-grok-hooks.py --approval
    python3 install-grok-hooks.py --uninstall
"""
import json
import os
import shutil
import sys

# Grok resolves its data directory from $GROK_HOME, falling back to ~/.grok, and
# reads standalone hook files from `<grok home>/hooks/*.json`. Honouring the same
# variable is what lets an isolated Grok (a test rig, a second profile) get its
# own hooks without touching the user's.
GROK_HOME = os.path.expanduser(os.environ.get("GROK_HOME") or "~/.grok")
HOOKS_DIR = os.path.join(GROK_HOME, "hooks")
TARGET = os.path.join(HOOKS_DIR, "vibebuddy.json")
BACKUP = TARGET + ".vibebuddy-backup"
HERE = os.path.dirname(os.path.abspath(__file__))
FORWARDER = os.path.join(HERE, "vibebuddy-forward.sh")
COMMAND = f'"{FORWARDER}" grok'
APPROVAL_HOOK = os.path.join(HERE, "approval-hook.sh")
APPROVAL_COMMAND = f'"{APPROVAL_HOOK}" grok'
CAPTURE_HOOK = os.path.join(HERE, "capture-terminal.sh")
# Grok reads a single-token `command` as a *path* — no shell, so the surrounding
# quotes stay in the string and it resolves to `<grok home>/hooks/"…"`, failing
# with `command not found` (verified against 1.0.13). A command with an argument
# is shell-parsed instead, which strips the quotes and survives spaces in the
# path, so the capture hook takes the same inert `grok` argument the forwarder
# does. `capture-terminal.sh` reads stdin and the env, never `$1`.
CAPTURE_COMMAND = f'"{CAPTURE_HOOK}" grok'
MARKER = "vibebuddy-forward.sh"
APPROVAL_MARKER = "approval-hook.sh"

# Status events. Grok accepts the PascalCase config keys and delivers the
# snake_case value in `hookEventName`.
EVENTS = [
    "SessionStart", "UserPromptSubmit",
    "PreToolUse", "PostToolUse", "PostToolUseFailure",
    "Stop", "StopFailure", "StopCancelled",
    "Notification", "SubagentStart", "SubagentStop",
    "SessionEnd",
]
# Terminal capture runs on SessionStart (new sessions) AND UserPromptSubmit (a
# session that missed SessionStart self-heals on its next prompt; writing the
# same ref is idempotent), matching the Claude installer.
CAPTURE_EVENTS = ["SessionStart", "UserPromptSubmit"]


def group(command, timeout=5):
    return {"hooks": [{"type": "command", "command": command, "timeout": timeout}]}


def build(approval=False):
    hooks = {ev: [group(COMMAND)] for ev in EVENTS}
    if approval:
        # The blocking gate subsumes the fire-and-forget PreToolUse update: it
        # reports the tool to the daemon via /approval?agent=grok itself. No
        # matcher = every tool. 30 s covers the phone round trip; a timeout
        # fails open.
        hooks["PreToolUse"] = [group(APPROVAL_COMMAND, timeout=30)]
    for ev in CAPTURE_EVENTS:
        hooks[ev].append(group(CAPTURE_COMMAND))
    return {"hooks": hooks}


def is_ours(path):
    try:
        with open(path) as f:
            return MARKER in f.read()
    except OSError:
        return False


def has_approval(path):
    """True when *our* file already wires the blocking approval gate."""
    try:
        with open(path) as f:
            content = f.read()
    except OSError:
        return False
    return MARKER in content and APPROVAL_MARKER in content


def write(payload):
    os.makedirs(HOOKS_DIR, exist_ok=True)
    # Back up a foreign file once; our own file is just overwritten.
    if os.path.exists(TARGET) and not is_ours(TARGET) and not os.path.exists(BACKUP):
        shutil.copy2(TARGET, BACKUP)
        print("backup written:", BACKUP)
    with open(TARGET, "w") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")


def reload_hint():
    print("reload in grok: /hooks → 'r', or start a new session.")


def main():
    args = sys.argv[1:]
    approval = "--approval" in args
    rest = [a for a in args if a != "--approval"]
    if rest:
        mode = rest[0]
    elif approval:
        # Bare `--approval` installs (mirrors install-claude-hooks.py); pair it
        # with `--dry-run` to preview the approval wiring.
        mode = "--install"
    else:
        mode = "--dry-run"

    # We rewrite the file wholesale, so a plain re-install (the Mac app's Repair
    # button among them) would silently drop an approval gate the user asked for.
    # Claude's installer preserves its gate the same way.
    if mode == "--install" and not approval and has_approval(TARGET):
        approval = True
        print("keeping the existing approval gate (--uninstall removes it)")

    if mode == "--dry-run":
        print("would write:", TARGET)
        print(json.dumps(build(approval), indent=2))
        return

    if mode == "--install":
        write(build(approval))
        label = "grok hooks + approval gate" if approval else "grok hooks"
        print(f"installed vibebuddy {label}:", TARGET)
        if approval:
            print('phone answers are authoritative only with '
                  '[ui] permission_mode = "always-approve" in ~/.grok/config.toml.')
        reload_hint()
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
