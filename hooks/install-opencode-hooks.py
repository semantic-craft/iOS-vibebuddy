#!/usr/bin/env python3
"""Install/uninstall the vibebuddy OpenCode plugin.

OpenCode auto-loads JS plugins from `~/.config/opencode/plugins/` at startup. We
copy `hooks/opencode/vibebuddy.js` there (it edge-normalizes OpenCode's typed
events to the Claude hook shape and POSTs to `/hook?agent=opencode`, fail-open).

Idempotent (byte-compare — re-install of identical content is a no-op), reversible
(`--uninstall` removes our copy; a pre-existing foreign `vibebuddy.js` is backed
up once and restored on uninstall).

Usage:
    python3 install-opencode-hooks.py --dry-run
    python3 install-opencode-hooks.py --install
    python3 install-opencode-hooks.py --uninstall
"""
import os
import shutil
import sys

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "opencode", "vibebuddy.js")
PLUGINS = os.path.expanduser("~/.config/opencode/plugins")
DST = os.path.join(PLUGINS, "vibebuddy.js")
BACKUP = DST + ".vibebuddy-backup"


def src_text():
    return open(SRC).read()


def is_ours(path):
    try:
        return open(path).read() == src_text()
    except OSError:
        return False


def main():
    mode = next((a for a in sys.argv[1:] if a in {"--dry-run", "--install", "--uninstall"}), "--dry-run")

    if mode == "--uninstall":
        if os.path.exists(DST) and is_ours(DST):
            os.remove(DST)
            if os.path.exists(BACKUP):
                shutil.move(BACKUP, DST)
                print("restored backup:", DST)
            else:
                print("removed opencode plugin:", DST)
        else:
            print("nothing to remove (not the vibebuddy plugin)")
        return

    if mode == "--dry-run":
        if is_ours(DST):
            state = "already installed (identical) — no-op"
        elif os.path.exists(DST):
            state = "would back up the existing file, then overwrite"
        else:
            state = "would install"
        print(f"opencode plugin: {state} -> {DST}")
        return

    if mode == "--install":
        os.makedirs(PLUGINS, exist_ok=True)
        if is_ours(DST):
            print("opencode plugin already installed (identical):", DST)
            return
        if os.path.exists(DST) and not os.path.exists(BACKUP):
            shutil.copy2(DST, BACKUP)
            print("backup written:", BACKUP)
        shutil.copy2(SRC, DST)
        print("installed opencode plugin:", DST)
        return

    print("unknown mode:", mode)
    sys.exit(2)


if __name__ == "__main__":
    main()
