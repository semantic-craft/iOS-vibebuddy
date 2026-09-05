#!/usr/bin/env python3
"""Universal vibebuddy hook installer — detect configured CLIs and wire each one.

Detects which coding CLIs are configured by the presence of their config dir/file
(NO PATH scanning), then delegates to the per-CLI installer for each, so all the
tested per-CLI hygiene (timestamped backup, marker / managed-region,
sanitize-then-append idempotency, reversibility, fail-open commands) is reused
rather than duplicated.

  --dry-run    list detected CLIs and what each would do
  --install    install vibebuddy hooks into every detected CLI
  --approval   install, and add the blocking phone-approval gate where the CLI
               supports one (Claude, Codex CLI, Grok); every other CLI gets --install
  --uninstall  remove vibebuddy hooks from every detected CLI

Idempotent: every per-CLI installer is idempotent, so a re-run is a no-op.
Fail-open: hooks are fire-and-forget; a down daemon never blocks any CLI. Codex
uses first-class lifecycle hooks, leaving its separate notify command untouched.
"""
import os
import subprocess
import sys

HOOKS_DIR = os.path.dirname(os.path.abspath(__file__))

# (name, detect-path, per-CLI installer). Detection is config presence only.
CLIS = [
    ("claude",      "~/.claude/settings.json",   "install-claude-hooks.py"),
    ("codex",       "~/.codex/config.toml",      "install-codex-hooks.py"),
    ("qwen",        "~/.qwen/settings.json",     "install-qwen-hooks.py"),
    ("grok",        "~/.grok",                   "install-grok-hooks.py"),
    ("antigravity", "~/.gemini/antigravity-cli", "install-antigravity-hooks.py"),
    ("kimi",        "~/.kimi-code/config.toml",  "install-kimi-hooks.py"),
    ("opencode",    "~/.config/opencode",        "install-opencode-hooks.py"),
]


# CLIs whose installer understands `--approval` (a blocking gate that asks the
# phone: PreToolUse for Claude and Grok, PermissionRequest for the Codex CLI).
# Everything else is installed status-only.
APPROVAL_CAPABLE = {"claude", "codex", "grok"}


def present(path):
    return os.path.exists(os.path.expanduser(path))


def run(script, mode):
    return subprocess.run(
        [sys.executable, os.path.join(HOOKS_DIR, script), mode],
        capture_output=True, text=True,
    )


def main():
    mode = next((a for a in sys.argv[1:]
                 if a in {"--dry-run", "--install", "--uninstall", "--approval"}), "--dry-run")
    found = [(n, p, s) for (n, p, s) in CLIS if present(p)]
    skipped = [n for (n, p, s) in CLIS if not present(p)]

    print(f"vibebuddy universal installer — {mode}")
    print("detected:", ", ".join(n for n, _, _ in found) or "(none)")
    if skipped:
        print("not configured (skipped):", ", ".join(skipped))

    failures = 0
    for (n, p, s) in found:
        print(f"\n=== {n}  ({s}) ===")
        cli_mode = mode
        if mode == "--approval" and n not in APPROVAL_CAPABLE:
            cli_mode = "--install"
        r = run(s, cli_mode)
        out = (r.stdout or "").strip()
        err = (r.stderr or "").strip()
        if out:
            print(out)
        if r.returncode != 0:
            failures += 1
            print(f"  ! {n} installer exited {r.returncode}: {err or '(no stderr)'}")
        elif err:
            print(err)

    print(f"\ndone: {len(found)} CLI(s) processed, {failures} failure(s).")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
