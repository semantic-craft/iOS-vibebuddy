#!/usr/bin/env python3
"""Idempotency + uninstall test for the universal installer (issue multi-cli/06).

Runs the real installers against a throwaway $HOME with minimal fake CLI configs
(so nothing on the real machine is touched), seeding a user-owned hook in the two
merge-into-existing configs (claude, kimi) to prove they survive uninstall.

Asserts:
  1. install is idempotent     — install twice → every managed file byte-identical
  2. uninstall is clean        — no vibebuddy markers remain
  3. user content is preserved — seeded user hooks survive install+uninstall

Run: python3 hooks/test_install_agent_hooks.py   (exit 0 = pass)
"""
import os
import subprocess
import sys
import tempfile

HOOKS = os.path.dirname(os.path.abspath(__file__))
UNIVERSAL = os.path.join(HOOKS, "install-agent-hooks.py")

# Files each detected CLI's installer writes (relative to $HOME).
MANAGED = [
    ".claude/settings.json",
    ".qwen/settings.json",
    ".grok/hooks/vibebuddy.json",
    ".gemini/antigravity-cli/hooks.json",
    ".kimi-code/config.toml",
    ".config/opencode/plugins/vibebuddy.js",
]
USER_CLAUDE_HOOK = "echo i-am-a-user-hook"
USER_KIMI_HOOK = "/Users/nobody/my-own-hook --source kimi"


def seed_home(home):
    def w(rel, content):
        p = os.path.join(home, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(content)
    # claude: a user PreToolUse hook that must survive
    w(".claude/settings.json",
      '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"%s"}]}]}}\n' % USER_CLAUDE_HOOK)
    w(".qwen/settings.json", "{}\n")
    os.makedirs(os.path.join(home, ".grok"), exist_ok=True)
    os.makedirs(os.path.join(home, ".gemini/antigravity-cli"), exist_ok=True)
    # kimi: a user [[hooks]] block + a scalar that must survive
    w(".kimi-code/config.toml",
      'default_model = "x"\n\n[[hooks]]\nevent = "Stop"\nmatcher = ""\n'
      'command = "%s"\ntimeout = 30\n' % USER_KIMI_HOOK)
    os.makedirs(os.path.join(home, ".config/opencode"), exist_ok=True)


def run(mode, home):
    env = {**os.environ, "HOME": home}
    return subprocess.run([sys.executable, UNIVERSAL, mode], env=env,
                          capture_output=True, text=True)


def snapshot(home):
    out = {}
    for rel in MANAGED:
        p = os.path.join(home, rel)
        out[rel] = open(p, "rb").read() if os.path.exists(p) else None
    return out


def main():
    fails = []
    with tempfile.TemporaryDirectory() as home:
        seed_home(home)

        r1 = run("--install", home)
        if r1.returncode != 0:
            fails.append(f"first --install exited {r1.returncode}: {r1.stderr}")
        snap1 = snapshot(home)

        r2 = run("--install", home)
        if r2.returncode != 0:
            fails.append(f"second --install exited {r2.returncode}: {r2.stderr}")
        snap2 = snapshot(home)

        # 1. idempotency: byte-identical across the two installs
        for rel in MANAGED:
            if snap1[rel] is None:
                fails.append(f"managed file never written: {rel}")
            elif snap1[rel] != snap2[rel]:
                fails.append(f"not idempotent (changed on re-install): {rel}")

        # 3a. user content present after install
        claude = open(os.path.join(home, ".claude/settings.json")).read()
        kimi = open(os.path.join(home, ".kimi-code/config.toml")).read()
        if USER_CLAUDE_HOOK not in claude:
            fails.append("install dropped the user's claude hook")
        if "9876/hook" not in claude:
            fails.append("install did not add a vibebuddy claude hook")
        if USER_KIMI_HOOK not in kimi or "vibebuddy-forward.sh kimi" not in kimi:
            fails.append("install broke kimi user hook or missed vibebuddy hook")

        # 2 + 3b. uninstall: clean of vibebuddy, user content preserved
        ru = run("--uninstall", home)
        if ru.returncode != 0:
            fails.append(f"--uninstall exited {ru.returncode}: {ru.stderr}")
        claude = open(os.path.join(home, ".claude/settings.json")).read()
        kimi = open(os.path.join(home, ".kimi-code/config.toml")).read()
        if "9876/hook" in claude or "capture-terminal.sh" in claude:
            fails.append("uninstall left vibebuddy markers in claude config")
        if USER_CLAUDE_HOOK not in claude:
            fails.append("uninstall removed the user's claude hook")
        if "vibebuddy-forward.sh" in kimi or "vibebuddy:" in kimi:
            fails.append("uninstall left vibebuddy markers in kimi config")
        if USER_KIMI_HOOK not in kimi or 'default_model = "x"' not in kimi:
            fails.append("uninstall removed kimi user content")
        if os.path.exists(os.path.join(home, ".grok/hooks/vibebuddy.json")):
            fails.append("uninstall left grok vibebuddy.json")
        if os.path.exists(os.path.join(home, ".config/opencode/plugins/vibebuddy.js")):
            fails.append("uninstall left opencode plugin")

    if fails:
        print("FAIL:")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("PASS: install idempotent, uninstall clean, user hooks preserved (6 CLIs)")


if __name__ == "__main__":
    main()
