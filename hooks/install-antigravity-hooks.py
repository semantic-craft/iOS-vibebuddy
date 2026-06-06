#!/usr/bin/env python3
"""Install/uninstall vibebuddy hooks for Antigravity (`agy`).

agy 1.0.5 loads hooks from **`~/.gemini/antigravity-cli/hooks.json`** (NOT the
`hooks` key in settings.json — that's upstream gemini-cli; agy diverges). The
schema was reverse-engineered from the live binary AND from what agy's own
`/hooks` TUI writes:

    {
      "<hookName>": {
        "PreToolUse":    [ { "matcher": "", "hooks": [ {type,command,timeout} ] } ],
        "PostToolUse":   [ ... ],
        "PreInvocation": [ ... ],
        "PostInvocation":[ ... ],
        "Stop":          [ ... ]
      }
    }

i.e. top-level keys are **hook names**, each name maps an **event** to an array of
**`{matcher, hooks}`** groups (hooks nest under matchers — `matcher:""` = match
all). agy logs `loaded N named hooks` on success.

Event surface (live `/hooks` TUI): PreToolUse, PostToolUse, PreInvocation,
PostInvocation, Stop. We wire command hooks → the shared forwarder
(`vibebuddy-forward.sh antigravity`); the daemon's source-aware HookDecoder runs
the Antigravity decoder. PostInvocation is omitted (redundant — PreInvocation
already marks the turn working).

KNOWN LIMITATION (agy-side, verified 2026-06-06): agy 1.0.5 *loads* this file
(`loaded 1 named hooks`) and its `/hooks` TUI shows the hook with an on/off toggle,
but agy does NOT *execute* the hook. This was checked exhaustively against every
controllable variable — correct path, correct schema (tool matcher-nested +
non-tool direct-handler, ingested unmangled), hook toggled ON, trusted workspace,
fresh session, real tool call — and nothing fired (no POST, not even non-tool
PreInvocation/Stop).

A second minimal repro also failed: explicit top-level `enabled: true`, only a
`PreToolUse` hook, official matcher `run_command`, and a capture command that
would append stdin to `/tmp/agy-cap.log` while returning `{"decision":"allow"}`.
Running `agy --prompt-interactive 'run the shell command: echo agy-hook-live-test'`
executed the Bash tool and logged `loaded 1 named hooks`, but never created the
capture file. Official docs say `enabled` defaults to true, and public issue
google-antigravity/antigravity-cli#222 reports the same load-but-skip symptom.

It's an agy-side execution bug, not a vibebuddy issue: the decoder + daemon path
are verified correct (synthetic E2E tags `agent=antigravity`). Re-check after an
agy update; the wiring here is ready the moment agy runs hooks.

Idempotent (manages the single `vibebuddy` named spec), reversible
(`--uninstall` removes it; backs up a foreign hooks.json once). Fail-open.

Usage:
    python3 install-antigravity-hooks.py --dry-run
    python3 install-antigravity-hooks.py --install
    python3 install-antigravity-hooks.py --uninstall
"""
import json
import os
import shutil
import sys

TARGET = os.path.expanduser("~/.gemini/antigravity-cli/hooks.json")
BACKUP = TARGET + ".vibebuddy-backup"
FORWARDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vibebuddy-forward.sh")
COMMAND = f'"{FORWARDER}" antigravity'
HOOK_NAME = "vibebuddy"

# agy 1.0.5 surface (confirmed live). PostInvocation omitted (redundant).
# Tool events nest hooks under a matcher; non-tool events take a DIRECT handler
# array (no matcher) — confirmed by how agy's TUI normalizes the file on toggle.
EVENTS = ["PreToolUse", "PostToolUse", "PreInvocation", "Stop"]
TOOL_EVENTS = {"PreToolUse", "PostToolUse"}


def handler():
    return {"type": "command", "command": COMMAND, "timeout": 5}


def spec():
    out = {}
    for ev in EVENTS:
        out[ev] = [{"matcher": "", "hooks": [handler()]}] if ev in TOOL_EVENTS else [handler()]
    return out


def load():
    if os.path.exists(TARGET):
        with open(TARGET) as f:
            return json.load(f)
    return {}


def write(hooks):
    os.makedirs(os.path.dirname(TARGET), exist_ok=True)
    if os.path.exists(TARGET) and not os.path.exists(BACKUP):
        shutil.copy2(TARGET, BACKUP)
        print("backup written:", BACKUP)
    with open(TARGET, "w") as f:
        json.dump(hooks, f, indent=2)
        f.write("\n")


def main():
    mode = next((a for a in sys.argv[1:] if a in {"--dry-run", "--install", "--uninstall"}), "--dry-run")
    hooks = load() if isinstance(load(), dict) else {}

    if mode == "--uninstall":
        existed = hooks.pop(HOOK_NAME, None) is not None
        if os.path.exists(TARGET):
            write(hooks)
            if not hooks:
                os.remove(TARGET)
        print("removed vibebuddy antigravity hook:", "yes" if existed else "(none)")
        return

    hooks[HOOK_NAME] = spec()   # overwrite our single named spec (idempotent)
    if mode == "--dry-run":
        print("would write:", TARGET)
        print(json.dumps(hooks, indent=2))
    elif mode == "--install":
        write(hooks)
        print("installed vibebuddy antigravity hook for events:", EVENTS)
        print("NOTE: agy 1.0.5 loads but does NOT execute hooks (verified) — see the "
              "KNOWN LIMITATION in the module docstring. Wiring is ready for when agy "
              "fixes hook execution.")
    else:
        print("unknown mode:", mode)
        sys.exit(2)


if __name__ == "__main__":
    main()
