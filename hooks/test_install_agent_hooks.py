#!/usr/bin/env python3
"""Idempotency + uninstall test for the universal installer (issue multi-cli/06).

Runs the real installers against a throwaway $HOME with minimal fake CLI configs
(so nothing on the real machine is touched), seeding user-owned hooks in the
merge-into-existing configs (claude, codex, kimi) to prove they survive uninstall.

Asserts:
  1. install is idempotent     — install twice → every managed file byte-identical
  2. uninstall is clean        — no vibebuddy markers remain
  3. user content is preserved — seeded user hooks survive install+uninstall

Run: python3 hooks/test_install_agent_hooks.py   (exit 0 = pass)
"""
import os
import json
import subprocess
import sys
import tempfile
import tomllib

HOOKS = os.path.dirname(os.path.abspath(__file__))
UNIVERSAL = os.path.join(HOOKS, "install-agent-hooks.py")

# Files each detected CLI's installer writes (relative to $HOME).
MANAGED = [
    ".claude/settings.json",
    ".codex/config.toml",
    ".codex/hooks.json",
    ".qwen/settings.json",
    ".grok/hooks/vibebuddy.json",
    ".gemini/antigravity-cli/hooks.json",
    ".kimi-code/config.toml",
    ".config/opencode/plugins/vibebuddy.js",
]
USER_CLAUDE_HOOK = "echo i-am-a-user-hook"
USER_CODEX_NOTIFY = ["/Applications/Existing Notifier.app/Contents/MacOS/notifier", "turn-ended"]
USER_CODEX_HOOK = "echo i-am-a-user-codex-hook"
USER_KIMI_HOOK = "/Users/nobody/my-own-hook --source kimi"


def seed_home(home):
    def w(rel, content):
        p = os.path.join(home, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(content)
    # claude: a user PreToolUse hook that must survive
    w(".claude/settings.json",
      '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"%s"}]}]}}\n' % USER_CLAUDE_HOOK)
    w(".codex/config.toml",
      'model = "gpt-test"\nnotify = ["%s", "%s"]\n\n[features]\nexample = true\n'
      % tuple(USER_CODEX_NOTIFY))
    w(".codex/hooks.json",
      '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n'
      % USER_CODEX_HOOK)
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
        codex = tomllib.loads(open(os.path.join(home, ".codex/config.toml")).read())
        codex_hooks = json.loads(open(os.path.join(home, ".codex/hooks.json")).read())
        kimi = open(os.path.join(home, ".kimi-code/config.toml")).read()
        if USER_CLAUDE_HOOK not in claude:
            fails.append("install dropped the user's claude hook")
        if "9876/hook" not in claude and "vibebuddy-forward.sh" not in claude:
            fails.append("install did not add a vibebuddy claude hook")
        permission_commands = [hook.get("command", "")
                               for group in json.loads(claude).get("hooks", {}).get("PermissionRequest", [])
                               for hook in group.get("hooks", [])]
        if not any("vibebuddy-forward.sh" in command or "9876/hook" in command
                   for command in permission_commands):
            fails.append("install missed the vibebuddy claude PermissionRequest hook")
        permission_hooks = [hook
                            for group in json.loads(claude).get("hooks", {}).get("PermissionRequest", [])
                            for hook in group.get("hooks", [])
                            if ("vibebuddy-forward.sh" in hook.get("command", "")
                                or "9876/hook" in hook.get("command", ""))]
        if not permission_hooks or permission_hooks[0].get("async") is not True:
            fails.append("claude status hooks are not async")
        for event in ["PostToolUseFailure", "PostToolBatch", "PermissionDenied",
                      "SubagentStart", "SubagentStop", "PreCompact", "PostCompact",
                      "StopFailure", "Elicitation", "ElicitationResult",
                      "TaskCreated", "TaskCompleted", "PostModelSwitch", "CwdChanged"]:
            groups = json.loads(claude).get("hooks", {}).get(event, [])
            managed = [hook for group in groups for hook in group.get("hooks", [])
                       if "vibebuddy-forward.sh" in hook.get("command", "")]
            if not managed:
                fails.append(f"install missed the current Claude {event} hook")
            elif managed[0].get("async") is not True:
                fails.append(f"Claude {event} hook is not async")
        if codex.get("notify") != USER_CODEX_NOTIFY:
            fails.append("install changed the user's codex notify command")
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                      "PermissionRequest", "PreCompact", "PostCompact", "SubagentStart",
                      "SubagentStop", "Stop", "Interrupt", "SessionEnd"]:
            groups = codex_hooks.get("hooks", {}).get(event, [])
            commands = [hook.get("command", "") for group in groups
                        for hook in group.get("hooks", [])]
            if not any("vibebuddy-forward.sh\" codex" in command for command in commands):
                fails.append(f"install missed the vibebuddy codex {event} hook")
            vibebuddy_hooks = [hook for group in groups for hook in group.get("hooks", [])
                               if "vibebuddy-forward.sh" in hook.get("command", "")]
            if not vibebuddy_hooks:
                fails.append(f"vibebuddy codex {event} hook is missing")
            else:
                if "async" in vibebuddy_hooks[0]:
                    fails.append(f"Codex {event} must omit unsupported async")
                if vibebuddy_hooks[0].get("timeout", 999) > 3:
                    fails.append(f"Codex {event} timeout exceeds the 3s runtime limit")
        session_start_commands = [hook.get("command", "")
                                  for group in codex_hooks["hooks"]["SessionStart"]
                                  for hook in group.get("hooks", [])]
        if USER_CODEX_HOOK not in session_start_commands:
            fails.append("install dropped the user's codex lifecycle hook")
        if USER_KIMI_HOOK not in kimi or "vibebuddy-forward.sh kimi" not in kimi:
            fails.append("install broke kimi user hook or missed vibebuddy hook")

        # 2 + 3b. uninstall: clean of vibebuddy, user content preserved
        ru = run("--uninstall", home)
        if ru.returncode != 0:
            fails.append(f"--uninstall exited {ru.returncode}: {ru.stderr}")
        claude = open(os.path.join(home, ".claude/settings.json")).read()
        codex = tomllib.loads(open(os.path.join(home, ".codex/config.toml")).read())
        codex_hooks = json.loads(open(os.path.join(home, ".codex/hooks.json")).read())
        kimi = open(os.path.join(home, ".kimi-code/config.toml")).read()
        if ("9876/hook" in claude or "vibebuddy-forward.sh" in claude
                or "capture-terminal.sh" in claude):
            fails.append("uninstall left vibebuddy markers in claude config")
        if USER_CLAUDE_HOOK not in claude:
            fails.append("uninstall removed the user's claude hook")
        if codex.get("notify") != USER_CODEX_NOTIFY:
            fails.append("uninstall changed the user's codex notify command")
        if codex.get("model") != "gpt-test" or codex.get("features", {}).get("example") is not True:
            fails.append("codex install/uninstall changed unrelated config")
        remaining_codex_commands = [hook.get("command", "")
                                    for groups in codex_hooks.get("hooks", {}).values()
                                    for group in groups for hook in group.get("hooks", [])]
        if any("vibebuddy-forward.sh" in command for command in remaining_codex_commands):
            fails.append("uninstall left vibebuddy codex lifecycle hooks")
        if USER_CODEX_HOOK not in remaining_codex_commands:
            fails.append("uninstall removed the user's codex lifecycle hook")
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
    print("PASS: install idempotent, uninstall clean, user hooks preserved (7 CLIs)")


if __name__ == "__main__":
    main()
