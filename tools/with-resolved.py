#!/usr/bin/env python3
"""Run a local Swift check without retaining SwiftPM's GUI-only pin pruning."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GUI_ONLY = {"menubarextraaccess", "sparkle"}


def is_cli_pruning(before, after):
    old, new = json.loads(before), json.loads(after)
    old_pins = {pin["identity"]: pin for pin in old["pins"]}
    new_pins = {pin["identity"]: pin for pin in new["pins"]}
    old_rest = {k: v for k, v in old.items() if k not in ("originHash", "pins")}
    new_rest = {k: v for k, v in new.items() if k not in ("originHash", "pins")}
    return (old_rest == new_rest and set(old_pins) - set(new_pins) <= GUI_ONLY
            and all(old_pins.get(key) == value for key, value in new_pins.items()))


def run(command, resolved):
    before = resolved.read_bytes() if resolved.exists() else None
    result = 1
    try:
        result = subprocess.run(command).returncode
    finally:
        after = resolved.read_bytes() if resolved.exists() else None
        if before is not None and after != before:
            try:
                expected = after is not None and is_cli_pruning(before, after)
            except (ValueError, KeyError, TypeError):
                expected = False
            if expected:
                resolved.write_bytes(before)
                print("Restored SwiftPM's GUI-only Package.resolved pruning.", flush=True)
            else:
                # Preserve both versions; an unexpected pin update is not ours to undo.
                with tempfile.NamedTemporaryFile(prefix="vibebuddy-resolved-", delete=False) as backup:
                    backup.write(before)
                print(f"Unexpected Package.resolved change retained; original: {backup.name}", file=sys.stderr)
                result = 1
    return result


if __name__ == "__main__":
    if len(sys.argv) == 1:
        sys.exit("Usage: tools/with-resolved.py <command> [args...]")
    sys.exit(run(sys.argv[1:], ROOT / "VibeBuddyMac/Package.resolved"))
