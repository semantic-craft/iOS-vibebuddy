#!/usr/bin/env python3
"""Install/uninstall vibebuddy hooks for Cursor (IDE + `cursor-agent` CLI).

Cursor reads one user-level hook file, `~/.cursor/hooks.json`, shaped
`{"version": 1, "hooks": {"<event>": [{"command": …, "timeout": …}]}}`, and it
watches that file and reloads on save. Because the file is shared with whatever
hooks the user wrote themselves, this installer *merges*: it only ever adds,
replaces or removes entries whose command is one of vibebuddy's own scripts, and
leaves every foreign entry untouched, in place and in order.

Two details of Cursor's contract shape the wiring:

  * A user-level hook runs with `~/.cursor/` as its working directory, so every
    command is written as an absolute path.
  * `preToolUse` fires for *every* tool — shell commands and MCP calls included —
    before Cursor's own permission check. That makes it the single place to put
    the blocking gate: wiring `beforeShellExecution` as well would raise two
    cards for one command.

Event set (Cursor's own camelCase names; `CursorParser` maps them):
  - lifecycle: sessionStart, sessionEnd
  - turn:      beforeSubmitPrompt, stop
  - tool:      preToolUse, postToolUse, postToolUseFailure, afterFileEdit
  - output:    afterAgentResponse
  - context:   preCompact
  - topology:  subagentStart, subagentStop

`stop` always runs `hooks/cursor-followup.sh`, which forwards the ending *and*
hands Cursor any follow-up the phone queued for a running turn
(`{"followup_message": …}`) — the one remote write Cursor documents. That entry
is written with `"loop_limit": null`: Cursor caps the automatic follow-ups it
accepts from one stop hook per conversation at 5 by default, and `null` removes
the cap (cursor.com/docs/hooks). Without it the sixth queued message from the
phone would be silently dropped.

If `~/.claude/settings.json` also carries vibebuddy's Claude Code hooks, Cursor
calls those too once "Include third-party Plugins, Skills, and other configs" is
on — with Cursor's own payload (cursor.com/docs/reference/third-party-hooks).
The daemon recognises that payload and keeps one session identity, so the
installer only says so; it never edits the Claude file.

`sessionStart` also runs `hooks/capture-terminal.sh cursor`, so a `cursor-agent`
session started in a terminal can be jumped back to. (An IDE chat has no
terminal; its jump brings Cursor forward instead.)

`--approval` additionally routes `preToolUse` through the blocking
`hooks/approval-hook.sh cursor`, which asks the phone and answers Cursor's own
`{"permission": …}` contract. The same gate carries Cursor's `AskQuestion` tool,
so a question the agent asks becomes a card the phone can answer. It replaces
(not joins) the fire-and-forget `preToolUse` entry, and a later plain `--install`
keeps it — only `--uninstall` removes it.

A timeout answers with no output, which Cursor reads as "no opinion" and falls
back to its own prompt. Nothing here can block Cursor: `failClosed` is never set.

Idempotent (re-run rewrites only our entries), reversible (`--uninstall` removes
them and deletes the file if nothing else is left).

Usage:
    python3 install-cursor-hooks.py --dry-run
    python3 install-cursor-hooks.py --install
    python3 install-cursor-hooks.py --approval
    python3 install-cursor-hooks.py --uninstall
"""
import json
import os
import shutil
import sys
import time

CURSOR_HOME = os.path.expanduser(os.environ.get("CURSOR_HOME") or "~/.cursor")
TARGET = os.path.join(CURSOR_HOME, "hooks.json")
HERE = os.path.dirname(os.path.abspath(__file__))
FORWARDER = os.path.join(HERE, "vibebuddy-forward.sh")
APPROVAL_HOOK = os.path.join(HERE, "approval-hook.sh")
CAPTURE_HOOK = os.path.join(HERE, "capture-terminal.sh")
FOLLOWUP_HOOK = os.path.join(HERE, "cursor-followup.sh")

COMMAND = f'"{FORWARDER}" cursor'
APPROVAL_COMMAND = f'"{APPROVAL_HOOK}" cursor'
CAPTURE_COMMAND = f'"{CAPTURE_HOOK}" cursor'
FOLLOWUP_COMMAND = f'"{FOLLOWUP_HOOK}"'

# Any entry whose command mentions one of these is ours, wherever it sits.
OURS = ("vibebuddy-forward.sh", "approval-hook.sh", "capture-terminal.sh",
        "cursor-followup.sh")

# Status events. `stop` is handled separately (it also collects follow-ups) and
# `preToolUse` separately (it is the gate in --approval mode).
STATUS_EVENTS = [
    "sessionStart", "sessionEnd",
    "beforeSubmitPrompt",
    "postToolUse", "postToolUseFailure", "afterFileEdit",
    "afterAgentResponse", "afterAgentThought", "preCompact",
    "subagentStart", "subagentStop",
]


def entry(command, timeout=5, **options):
    return {"command": command, "timeout": timeout, **options}


def desired(approval=False):
    """The entries vibebuddy wants, per event, in order."""
    hooks = {event: [entry(COMMAND)] for event in STATUS_EVENTS}
    # 30 s covers the phone round trip; a timeout prints nothing and Cursor asks
    # on its own. In status-only mode the same event is a plain progress report.
    hooks["preToolUse"] = [entry(APPROVAL_COMMAND, timeout=30)] if approval else [entry(COMMAND)]
    # The follow-up collector must finish inside Cursor's patience for a `stop`
    # hook; it only reads a local queue, so 5 s is generous. `loop_limit: null`
    # lifts Cursor's default cap of 5 automatic follow-ups per conversation, so
    # every message the phone queues is handed over, not just the first five.
    hooks["stop"] = [entry(FOLLOWUP_COMMAND, loop_limit=None)]
    hooks["sessionStart"].append(entry(CAPTURE_COMMAND, timeout=10))
    return hooks


def load():
    """The user's current file, or a fresh document. A file we cannot parse is
    never silently replaced — the caller backs it up first."""
    try:
        with open(TARGET) as f:
            document = json.load(f)
    except FileNotFoundError:
        return {"version": 1, "hooks": {}}, True
    except (OSError, ValueError):
        return None, False
    if not isinstance(document, dict):
        return None, False
    document.setdefault("version", 1)
    hooks = document.get("hooks")
    if not isinstance(hooks, dict):
        document["hooks"] = {}
    return document, True


def is_ours(item):
    if not isinstance(item, dict):
        return False
    command = item.get("command")
    if not isinstance(command, str):
        return False
    return any(marker in command for marker in OURS)


def merge(document, wanted):
    """Replace our entries with `wanted`, keep every foreign entry as it was."""
    hooks = document["hooks"]
    for event in list(hooks):
        items = hooks[event]
        if not isinstance(items, list):
            continue
        kept = [item for item in items if not is_ours(item)]
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    for event, items in wanted.items():
        hooks.setdefault(event, [])
        hooks[event] = items + hooks[event]
    return document


def strip(document):
    hooks = document["hooks"]
    removed = 0
    for event in list(hooks):
        items = hooks[event]
        if not isinstance(items, list):
            continue
        kept = [item for item in items if not is_ours(item)]
        removed += len(items) - len(kept)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    return document, removed


def installed_state():
    """(ours present, approval gate present) for the current file."""
    try:
        with open(TARGET) as f:
            content = f.read()
    except OSError:
        return False, False
    ours = any(marker in content for marker in OURS)
    return ours, "approval-hook.sh" in content


def backup():
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = f"{TARGET}.vibebuddy-backup-{stamp}"
    shutil.copy2(TARGET, path)
    print("backup written:", path)


def write(document):
    os.makedirs(CURSOR_HOME, exist_ok=True)
    with open(TARGET, "w") as f:
        json.dump(document, f, indent=2)
        f.write("\n")


def note_third_party_overlap():
    """One line when Claude Code's settings also carry vibebuddy hooks. Cursor
    calls Claude Code hooks with its own payload once third-party hooks are
    enabled; the daemon routes that payload to the Cursor parser, so this is
    information, not a conflict, and the Claude file is left alone."""
    path = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
    try:
        with open(path) as f:
            content = f.read()
    except OSError:
        return
    if "vibebuddy" in content:
        print("note: ~/.claude/settings.json also carries vibebuddy hooks; if Cursor's "
              "third-party hooks are enabled, Cursor will call them too — vibebuddy "
              "recognises the Cursor payload and keeps one session identity.")


def main():
    args = sys.argv[1:]
    approval = "--approval" in args
    rest = [a for a in args if a != "--approval"]
    mode = rest[0] if rest else ("--install" if approval else "--dry-run")

    # A plain re-install (the Mac app's Repair button among them) must not drop a
    # gate the user asked for, the way the Claude and Grok installers keep theirs.
    _, had_approval = installed_state()
    if mode == "--install" and not approval and had_approval:
        approval = True
        print("keeping the existing approval gate (--uninstall removes it)")

    document, parsed = load()
    if document is None:
        if mode == "--dry-run":
            print(f"{TARGET} exists but is not readable JSON; --install would back it up first.")
            return
        print(f"! {TARGET} is not readable JSON — backing it up and starting a fresh file.")
        backup()
        document, parsed = {"version": 1, "hooks": {}}, True

    if mode == "--dry-run":
        merged = merge(json.loads(json.dumps(document)), desired(approval))
        print("would write:", TARGET)
        print(json.dumps(merged, indent=2))
        note_third_party_overlap()
        return

    if mode == "--install":
        if os.path.exists(TARGET):
            ours, _ = installed_state()
            if not ours:
                backup()
        write(merge(document, desired(approval)))
        label = "Cursor hooks + approval gate" if approval else "Cursor hooks"
        print(f"installed vibebuddy {label}:", TARGET)
        print("Cursor watches hooks.json and reloads on save; restart Cursor if it does not pick it up.")
        if approval:
            print("phone approvals answer Cursor's own permission contract; a timeout "
                  "prints nothing and Cursor asks in its own UI.")
        note_third_party_overlap()
        return

    if mode == "--uninstall":
        if not os.path.exists(TARGET):
            print("nothing to remove (no ~/.cursor/hooks.json)")
            return
        document, removed = strip(document)
        if not removed:
            print("nothing to remove (not installed by vibebuddy)")
            return
        if document["hooks"]:
            write(document)
            print(f"removed {removed} vibebuddy hook entries, kept your own:", TARGET)
        else:
            os.remove(TARGET)
            print("removed:", TARGET)
        return

    print("unknown mode:", mode)
    sys.exit(2)


if __name__ == "__main__":
    main()
