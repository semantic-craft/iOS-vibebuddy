#!/usr/bin/env python3
"""Install/uninstall vibebuddy hooks for Kimi Code (`kimi`).

Kimi Code (migrated to `~/.kimi-code/`) configures hooks as TOML `[[hooks]]`
blocks in `~/.kimi-code/config.toml`, with Claude-style event names and a
`command` hook. Its stdin envelope is **native Claude shape**
(`{hook_event_name, session_id, cwd, tool_name, tool_response}` — verified live),
so NO daemon decoder is needed: events route through HookDecoder's default
Claude-shape passthrough, tagged `kimi`. This is config-only, like Qwen.

We add command hooks → the shared forwarder (`vibebuddy-forward.sh kimi`) for the
status lifecycle, plus `capture-terminal.sh` on SessionStart/UserPromptSubmit for
jump-to-terminal (kimi's claude-shape stdin carries `session_id`). Existing
non-vibebuddy hooks (e.g. VibeIsland) are preserved untouched.

Idempotent (sanitize-then-append our marked region), reversible (`--uninstall`
removes only our blocks), backs up the config once. Fail-open.

Usage:
    python3 install-kimi-hooks.py --dry-run
    python3 install-kimi-hooks.py --install
    python3 install-kimi-hooks.py --uninstall
"""
import os
import re
import shutil
import sys

CONFIG = os.path.expanduser("~/.kimi-code/config.toml")
BACKUP = CONFIG + ".vibebuddy-backup"
HOOKS_DIR = os.path.dirname(os.path.abspath(__file__))
FORWARDER = os.path.join(HOOKS_DIR, "vibebuddy-forward.sh")
CAPTURE = os.path.join(HOOKS_DIR, "capture-terminal.sh")
MARKERS = ("vibebuddy-forward.sh", "capture-terminal.sh", "vibebuddy:")

BEGIN = "# vibebuddy:begin (managed — do not edit by hand)"
END = "# vibebuddy:end"

# Claude-style lifecycle events kimi emits; Notification gets a long timeout
# (it can block waiting on the user), matching kimi/VibeIsland convention.
FORWARD_EVENTS = [
    ("SessionStart", 30), ("SessionEnd", 30), ("UserPromptSubmit", 30),
    ("PreToolUse", 30), ("PostToolUse", 30), ("Stop", 30), ("Notification", 600),
]
CAPTURE_EVENTS = ["SessionStart", "UserPromptSubmit"]


def strip_vibebuddy(text):
    """Remove our marked region and any stray vibebuddy `[[hooks]]` blocks,
    preserving every other hook block and the rest of the file."""
    # 1) Drop a whole BEGIN..END region if present.
    text = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?", "", text, flags=re.DOTALL)
    # 2) Drop any leftover individual `[[hooks]]` block that points at vibebuddy,
    #    along with an immediately-preceding vibebuddy marker comment line.
    out, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        if lines[i].strip() == "[[hooks]]":
            j = i + 1
            while j < len(lines) and lines[j].strip() != "[[hooks]]" and not lines[j].lstrip().startswith("["):
                j += 1
            block = "\n".join(lines[i:j])
            if any(m in block for m in MARKERS):
                # drop block; also pop a trailing marker comment / blank we already kept
                while out and (out[-1].strip() == "" or (out[-1].lstrip().startswith("#") and "vibebuddy" in out[-1])):
                    popped = out.pop()
                    if popped.lstrip().startswith("#"):
                        break
                i = j
                continue
            out.extend(lines[i:j])
            i = j
        else:
            out.append(lines[i])
            i += 1
    return "\n".join(out).rstrip("\n") + "\n"


def block(event, command, timeout):
    return (f'[[hooks]]\nevent = "{event}"\nmatcher = ""\n'
            f'command = "{command}"\ntimeout = {timeout}\n')


def region():
    # Paths have no spaces; leave them unquoted inside the TOML string (matches
    # kimi/VibeIsland convention) so the value stays valid TOML.
    parts = [BEGIN]
    for ev, t in FORWARD_EVENTS:
        parts.append(block(ev, f"{FORWARDER} kimi", t))
    for ev in CAPTURE_EVENTS:
        parts.append(block(ev, CAPTURE, 10))
    parts.append(END)
    return "\n".join(parts) + "\n"


def main():
    mode = next((a for a in sys.argv[1:] if a in {"--dry-run", "--install", "--uninstall"}), "--dry-run")
    if not os.path.exists(CONFIG):
        print("no kimi config at", CONFIG)
        sys.exit(1)
    original = open(CONFIG).read()
    cleaned = strip_vibebuddy(original)

    if mode == "--uninstall":
        if not os.path.exists(BACKUP):
            shutil.copy2(CONFIG, BACKUP)
        open(CONFIG, "w").write(cleaned)
        print("removed vibebuddy kimi hooks from:", CONFIG)
        return

    new = cleaned.rstrip("\n") + "\n\n" + region()
    if mode == "--dry-run":
        print("would write the vibebuddy region to:", CONFIG)
        print(region())
    elif mode == "--install":
        if not os.path.exists(BACKUP):
            shutil.copy2(CONFIG, BACKUP)
            print("backup written:", BACKUP)
        open(CONFIG, "w").write(new)
        print("installed vibebuddy kimi hooks for:",
              [e for e, _ in FORWARD_EVENTS], "+ terminal capture")
        print("restart kimi to load. validate: ~/.kimi-code/bin/kimi doctor")
    else:
        print("unknown mode:", mode)
        sys.exit(2)


if __name__ == "__main__":
    main()
