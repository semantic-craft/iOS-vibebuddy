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
# The grok 1.0.13 event set install-grok-hooks.py registers.
GROK_EVENTS = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "Stop", "StopFailure", "StopCancelled",
    "Notification", "SubagentStart", "SubagentStop", "SessionEnd",
]


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
    # An ambient $GROK_HOME would redirect the grok installer away from the
    # throwaway $HOME this pass asserts against.
    env.pop("GROK_HOME", None)
    return subprocess.run([sys.executable, UNIVERSAL, mode], env=env,
                          capture_output=True, text=True)


def check_grok_home(fails):
    """install-grok-hooks.py writes under $GROK_HOME, not just ~/.grok."""
    installer = os.path.join(HOOKS, "install-grok-hooks.py")
    with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as grok_home:
        env = {**os.environ, "HOME": home, "GROK_HOME": grok_home}
        r = subprocess.run([sys.executable, installer, "--install"], env=env,
                           capture_output=True, text=True)
        if r.returncode != 0:
            fails.append(f"GROK_HOME install exited {r.returncode}: {r.stderr}")
        target = os.path.join(grok_home, "hooks/vibebuddy.json")
        if not os.path.exists(target):
            fails.append("install-grok-hooks.py ignored $GROK_HOME")
            return
        if os.path.exists(os.path.join(home, ".grok/hooks/vibebuddy.json")):
            fails.append("$GROK_HOME install also wrote to ~/.grok")
        hooks = json.loads(open(target).read())["hooks"]
        for event in GROK_EVENTS:
            commands = [hook.get("command", "") for group in hooks.get(event, [])
                        for hook in group.get("hooks", [])]
            if not any('vibebuddy-forward.sh" grok' in command for command in commands):
                fails.append(f"$GROK_HOME install missed the {event} hook")
        # uninstall must clean the same redirected location
        ru = subprocess.run([sys.executable, installer, "--uninstall"], env=env,
                            capture_output=True, text=True)
        if ru.returncode != 0:
            fails.append(f"GROK_HOME uninstall exited {ru.returncode}: {ru.stderr}")
        if os.path.exists(target):
            fails.append("uninstall left vibebuddy.json under $GROK_HOME")


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

        # grok: the full 1.0.13 event set through the forwarder, plus terminal
        # capture on the two events the Claude installer uses.
        grok_hooks = json.loads(open(os.path.join(home, ".grok/hooks/vibebuddy.json")).read())["hooks"]
        for event in GROK_EVENTS:
            commands = [hook.get("command", "") for group in grok_hooks.get(event, [])
                        for hook in group.get("hooks", [])]
            if not any('vibebuddy-forward.sh" grok' in command for command in commands):
                fails.append(f"install missed the vibebuddy grok {event} hook")
        for event in ["SessionStart", "UserPromptSubmit"]:
            commands = [hook.get("command", "") for group in grok_hooks.get(event, [])
                        for hook in group.get("hooks", [])]
            capture = [c for c in commands if "capture-terminal.sh" in c]
            if not capture:
                fails.append(f"install missed the grok {event} terminal capture")
            # Grok resolves an argument-less command as a literal path relative to
            # the hooks dir, quotes included, so a bare `"…/capture-terminal.sh"`
            # never runs. It must carry an argument to be shell-parsed.
            elif capture[0].strip().endswith('"'):
                fails.append(f"grok {event} capture is a bare quoted path (grok "
                             "resolves it relative to the hooks dir and it never runs)")
        approval_commands = [hook.get("command", "") for group in grok_hooks.get("PreToolUse", [])
                             for hook in group.get("hooks", [])]
        if any("approval-hook.sh" in command for command in approval_commands):
            fails.append("plain --install must not add the grok approval gate")

        # --approval: the blocking gate replaces the fire-and-forget PreToolUse
        # group for the CLIs that support it, and leaves the rest installed.
        ra = run("--approval", home)
        if ra.returncode != 0:
            fails.append(f"--approval exited {ra.returncode}: {ra.stderr}")
        grok_hooks = json.loads(open(os.path.join(home, ".grok/hooks/vibebuddy.json")).read())["hooks"]
        pre_tool = [hook for group in grok_hooks.get("PreToolUse", [])
                    for hook in group.get("hooks", [])]
        if not any("approval-hook.sh" in hook.get("command", "") for hook in pre_tool):
            fails.append("--approval did not add the grok approval gate")
        if any("vibebuddy-forward.sh" in hook.get("command", "") for hook in pre_tool):
            fails.append("--approval left the fire-and-forget grok PreToolUse group")
        if not all(hook.get("timeout") == 30 for hook in pre_tool):
            fails.append("grok approval gate must allow 30s for the phone round trip")
        if not any(hook.get("command", "").endswith('" grok') for hook in pre_tool):
            fails.append("grok approval gate must pass the grok source argument")
        claude_pre_tool = [hook for group in json.loads(
                               open(os.path.join(home, ".claude/settings.json")).read()
                           ).get("hooks", {}).get("PreToolUse", [])
                           for hook in group.get("hooks", [])]
        if not any("approval-hook.sh" in hook.get("command", "") for hook in claude_pre_tool):
            fails.append("--approval did not add the claude approval gate")
        if "Stop" not in grok_hooks:
            fails.append("--approval dropped the grok status hooks")

        # codex: the gate sits on PermissionRequest (the only event whose hook
        # decision Codex honours for an allow); PreToolUse keeps its status
        # forwarder so the session still goes `working` once the tool runs.
        codex_hooks = json.loads(open(os.path.join(home, ".codex/hooks.json")).read())["hooks"]
        codex_gate = [hook for group in codex_hooks.get("PermissionRequest", [])
                      for hook in group.get("hooks", [])]
        if not any("approval-hook.sh" in hook.get("command", "") for hook in codex_gate):
            fails.append("--approval did not add the codex approval gate on PermissionRequest")
        if any("vibebuddy-forward.sh" in hook.get("command", "") for hook in codex_gate):
            fails.append("--approval left the fire-and-forget codex PermissionRequest group")
        if not all(hook.get("timeout") == 30 for hook in codex_gate
                   if "approval-hook.sh" in hook.get("command", "")):
            fails.append("codex approval gate must allow 30s for the phone round trip")
        if not any(hook.get("command", "").endswith('" codex') for hook in codex_gate):
            fails.append("codex approval gate must pass the codex source argument")
        codex_pre_tool = [hook.get("command", "") for group in codex_hooks.get("PreToolUse", [])
                          for hook in group.get("hooks", [])]
        if not any('vibebuddy-forward.sh" codex' in command for command in codex_pre_tool):
            fails.append("--approval dropped the codex PreToolUse status forwarder")
        if any("approval-hook.sh" in command for command in codex_pre_tool):
            fails.append("codex approval gate must not sit on PreToolUse (Codex rejects allow there)")
        if USER_CODEX_HOOK not in [hook.get("command", "")
                                   for group in codex_hooks.get("SessionStart", [])
                                   for hook in group.get("hooks", [])]:
            fails.append("--approval dropped the user's codex lifecycle hook")

        # A plain re-install (the Mac app's Repair button) rewrites the grok file
        # wholesale; it must not silently drop the gate the user opted into.
        rr = run("--install", home)
        if rr.returncode != 0:
            fails.append(f"re-install after --approval exited {rr.returncode}: {rr.stderr}")
        grok_hooks = json.loads(open(os.path.join(home, ".grok/hooks/vibebuddy.json")).read())["hooks"]
        pre_tool = [hook for group in grok_hooks.get("PreToolUse", [])
                    for hook in group.get("hooks", [])]
        if not any("approval-hook.sh" in hook.get("command", "") for hook in pre_tool):
            fails.append("plain --install dropped the existing grok approval gate")
        if "Stop" not in grok_hooks:
            fails.append("re-install after --approval dropped the grok status hooks")
        claude_pre_tool = [hook for group in json.loads(
                               open(os.path.join(home, ".claude/settings.json")).read()
                           ).get("hooks", {}).get("PreToolUse", [])
                           for hook in group.get("hooks", [])]
        if not any("approval-hook.sh" in hook.get("command", "") for hook in claude_pre_tool):
            fails.append("plain --install dropped the existing claude approval gate")
        codex_hooks = json.loads(open(os.path.join(home, ".codex/hooks.json")).read())["hooks"]
        codex_gate = [hook.get("command", "") for group in codex_hooks.get("PermissionRequest", [])
                      for hook in group.get("hooks", [])]
        if not any("approval-hook.sh" in command for command in codex_gate):
            fails.append("plain --install dropped the existing codex approval gate")
        if any("vibebuddy-forward.sh" in command for command in codex_gate):
            fails.append("re-install after --approval re-added the codex PermissionRequest forwarder")

        # Grok imports ~/.claude/settings.json hooks and resolves a quoted,
        # argument-less command as a literal path, so the Claude capture hook
        # carries an inert argument too.
        claude_capture = [hook.get("command", "")
                          for event in ["SessionStart", "UserPromptSubmit"]
                          for group in json.loads(
                              open(os.path.join(home, ".claude/settings.json")).read()
                          ).get("hooks", {}).get(event, [])
                          for hook in group.get("hooks", [])
                          if "capture-terminal.sh" in hook.get("command", "")]
        if len(claude_capture) != 2:
            fails.append("claude capture hook missing on SessionStart/UserPromptSubmit")
        if any(command.strip().endswith('"') for command in claude_capture):
            fails.append("claude capture is a bare quoted path (grok's compat "
                         "bridge resolves it as a literal path and it never runs)")

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
        if any("approval-hook.sh" in command for command in remaining_codex_commands):
            fails.append("uninstall left the codex approval gate")
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

    check_grok_home(fails)

    if fails:
        print("FAIL:")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("PASS: install idempotent, approval gates wired, uninstall clean, "
          "user hooks preserved (7 CLIs)")


if __name__ == "__main__":
    main()
