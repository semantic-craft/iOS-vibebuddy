#!/usr/bin/env python3
"""A CLI build may prune GUI pins; changed dependency versions must be preserved."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("resolved", Path(__file__).resolve().parents[1] / "with-resolved.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="vb-resolved-test-") as folder:
    path = Path(folder) / "Package.resolved"
    original = {"version": 3, "originHash": "gui", "pins": [
        {"identity": "sparkle", "state": {"version": "1"}},
        {"identity": "core", "state": {"version": "1"}}]}
    path.write_text(json.dumps(original))
    original_bytes = path.read_bytes()
    pruned = {**original, "originHash": "cli", "pins": [original["pins"][1]]}
    # Fail the child too: cleanup must restore pins on build failure as well.
    command = [sys.executable, "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2]);sys.exit(7)", str(path), json.dumps(pruned)]
    assert module.run(command, path) == 7
    assert path.read_bytes() == original_bytes
    print("PASS GUI-only pin pruning restored on failed command")
    changed = {**pruned, "pins": [{"identity": "core", "state": {"version": "2"}}]}
    command[-1] = json.dumps(changed)
    assert module.run(command, path) == 1
    assert json.loads(path.read_bytes()) == changed
    print("PASS unexpected version change retained and reported as failure")

    path.write_bytes(original_bytes)
    changed = {**original, "originHash": "new-manifest"}
    command[-1] = json.dumps(changed)
    assert module.run(command, path) == 1
    assert json.loads(path.read_bytes()) == changed
    print("PASS hash-only change retained and reported as failure")
