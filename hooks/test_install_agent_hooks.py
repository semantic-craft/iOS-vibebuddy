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
    # Pin the Claude version probe so the assertions below do not depend on the
    # `claude` binary (or its age) on the machine running this test.
    env = {**os.environ, "HOME": home, "VIBEBUDDY_CLAUDE_VERSION": "2.1.261"}
    # An ambient $GROK_HOME would redirect the grok installer away from the
    # throwaway $HOME this pass asserts against.
    env.pop("GROK_HOME", None)
    return subprocess.run([sys.executable, UNIVERSAL, mode], env=env,
                          capture_output=True, text=True)


def check_codex_hooks_feature(fails):
    """Both scanners use these configs; real CLI output must not rewrite TOML."""
    installer = os.path.join(HOOKS, "install-codex-hooks.py")
    with open(os.path.join(HOOKS, "fixtures/codex-hooks-feature.json")) as handle:
        fixtures = json.load(handle)
    for fixture in fixtures:
        with tempfile.TemporaryDirectory() as home:
            directory = os.path.join(home, ".codex")
            os.makedirs(directory)
            config = os.path.join(directory, "config.toml")
            original = fixture["config"].encode()
            with open(config, "wb") as handle:
                handle.write(original)
            for mode in ["--dry-run", "--install", "--approval", "--uninstall"]:
                result = subprocess.run([sys.executable, installer, mode],
                                        env={**os.environ, "HOME": home},
                                        capture_output=True, text=True)
                warned = "codex features enable hooks" in result.stdout
                expected = fixture["disabled"] and mode != "--uninstall"
                if result.returncode != 0 or warned != expected:
                    fails.append(f"Codex feature {fixture['name']} {mode}: wrong warning/exit")
                with open(config, "rb") as handle:
                    if handle.read() != original:
                        fails.append("Codex feature diagnostic changed config.toml")


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


def check_statusline_only(fails):
    """The explicit optional-source action never edits hooks or their approval gates."""
    with tempfile.TemporaryDirectory() as home:
        settings = os.path.join(home, ".claude/settings.json")
        os.makedirs(os.path.dirname(settings))
        original = {"hooks": {"PermissionRequest": [{"hooks": [{"command": "user gate"}]}]},
                    "statusLine": {"type": "command", "command": "echo existing", "padding": 2}}
        with open(settings, "w") as f:
            json.dump(original, f)
        env = {"HOME": home, "PATH": "/usr/bin:/bin",
               "VIBEBUDDY_SUPPORT_DIR": os.path.join(home, "support")}
        previous = None
        for _ in range(2):
            result = subprocess.run([sys.executable, os.path.join(HOOKS, "install-claude-hooks.py"),
                                     "--statusline"], env=env, capture_output=True, text=True)
            current = open(settings).read()
            if result.returncode or json.loads(current)["hooks"] != original["hooks"]:
                fails.append("statusline-only action failed or changed hooks")
            if previous is not None and current != previous:
                fails.append("statusline-only action is not idempotent")
            previous = current
            if json.load(open(settings + ".vibebuddy-backup")) != original:
                fails.append("statusline-only action changed its settings backup")
            if json.load(open(os.path.join(home, "support/statusline-original.json")))["statusLine"] != original["statusLine"]:
                fails.append("statusline-only action changed original status line")


def check_claude_statusline_wrapper(fails):
    """--install wraps the user's status line (keeping its other fields and
    saving the original command for the wrapper to run), --uninstall restores
    it exactly; with no original, --install adds one and --uninstall removes it."""
    installer = os.path.join(HOOKS, "install-claude-hooks.py")
    with tempfile.TemporaryDirectory() as home:
        settings = os.path.join(home, ".claude/settings.json")
        os.makedirs(os.path.dirname(settings), exist_ok=True)
        support = os.path.join(home, "Library/Application Support/vibebuddy")
        env = {**os.environ, "HOME": home, "VIBEBUDDY_CLAUDE_VERSION": "2.1.261",
               "VIBEBUDDY_SUPPORT_DIR": support}
        original = {"type": "command", "command": "~/.claude/statusline.sh", "padding": 1}
        open(settings, "w").write(json.dumps({"statusLine": original}))
        r = subprocess.run([sys.executable, installer, "--install"], env=env,
                           capture_output=True, text=True)
        if r.returncode != 0:
            fails.append(f"statusline --install exited {r.returncode}: {r.stderr}")
            return
        line = json.loads(open(settings).read()).get("statusLine", {})
        if "vibebuddy-statusline.sh" not in line.get("command", ""):
            fails.append("--install did not wrap the claude status line")
        if line.get("padding") != 1:
            fails.append("status line wrapper dropped the original's other fields")
        cmd_file = os.path.join(support, "statusline-original.cmd")
        if not os.path.exists(cmd_file) or open(cmd_file).read() != "~/.claude/statusline.sh":
            fails.append("status line install did not save the original command for the wrapper")
        # Re-install is idempotent and must not overwrite the saved original.
        subprocess.run([sys.executable, installer, "--install"], env=env, capture_output=True, text=True)
        if open(cmd_file).read() != "~/.claude/statusline.sh":
            fails.append("re-install overwrote the saved original status line command")
        ru = subprocess.run([sys.executable, installer, "--uninstall"], env=env,
                            capture_output=True, text=True)
        if ru.returncode != 0:
            fails.append(f"statusline --uninstall exited {ru.returncode}: {ru.stderr}")
        if json.loads(open(settings).read()).get("statusLine") != original:
            fails.append("--uninstall did not restore the original status line")
        if os.path.exists(cmd_file):
            fails.append("--uninstall left the saved original status line command")

        # No original: install adds the wrapper alone, uninstall removes the key.
        open(settings, "w").write("{}")
        subprocess.run([sys.executable, installer, "--install"], env=env, capture_output=True, text=True)
        line = json.loads(open(settings).read()).get("statusLine", {})
        if "vibebuddy-statusline.sh" not in line.get("command", ""):
            fails.append("--install did not add a status line when there was none")
        if open(cmd_file).read() != "":
            fails.append("status line install with no original saved a command")
        subprocess.run([sys.executable, installer, "--uninstall"], env=env, capture_output=True, text=True)
        if "statusLine" in json.loads(open(settings).read()):
            fails.append("--uninstall left a status line that was not there before")


def check_claude_old_cli_keeps_legacy_gate(fails):
    """On a Claude Code older than 2.1.257 the PermissionRequest reply is not
    honoured, so --approval must keep the gate on PreToolUse and say why; once
    the CLI is updated a plain --install migrates it."""
    installer = os.path.join(HOOKS, "install-claude-hooks.py")
    with tempfile.TemporaryDirectory() as home:
        settings = os.path.join(home, ".claude/settings.json")

        def gates(event):
            # The AskUserQuestion group is a question relay, not the permission
            # gate; it is expected on PreToolUse whenever the modern gate is.
            hooks = json.loads(open(settings).read()).get("hooks", {})
            return [h.get("command", "") for g in hooks.get(event, [])
                    if g.get("matcher") != "AskUserQuestion" for h in g.get("hooks", [])]

        old = {**os.environ, "HOME": home, "VIBEBUDDY_CLAUDE_VERSION": "2.1.200 (Claude Code)"}
        r = subprocess.run([sys.executable, installer, "--approval"], env=old,
                           capture_output=True, text=True)
        if r.returncode != 0:
            fails.append(f"old-cli --approval exited {r.returncode}: {r.stderr}")
            return
        if not any("approval-hook.sh" in c for c in gates("PreToolUse")):
            fails.append("old CLI: --approval did not keep the gate on PreToolUse")
        if any("approval-hook.sh" in c for c in gates("PermissionRequest")):
            fails.append("old CLI: --approval put the gate on PermissionRequest it cannot answer")
        if "older than 2.1.257" not in r.stdout:
            fails.append("old CLI: --approval did not warn about the legacy gate")
        new = {**os.environ, "HOME": home, "VIBEBUDDY_CLAUDE_VERSION": "2.1.261"}
        r2 = subprocess.run([sys.executable, installer, "--install"], env=new,
                            capture_output=True, text=True)
        if r2.returncode != 0:
            fails.append(f"updated-cli --install exited {r2.returncode}: {r2.stderr}")
            return
        if any("approval-hook.sh" in c for c in gates("PreToolUse")):
            fails.append("updated CLI: --install left the legacy gate on PreToolUse")
        if not any("approval-hook.sh" in c for c in gates("PermissionRequest")):
            fails.append("updated CLI: --install did not migrate the gate to PermissionRequest")
        if "older than" in r2.stdout:
            fails.append("updated CLI: --install still warned about the legacy gate")


def check_claude_legacy_gate_migration(fails):
    """A pre-PermissionRequest install left the gate on PreToolUse, holding every
    tool call; a plain --install must move it to PermissionRequest."""
    installer = os.path.join(HOOKS, "install-claude-hooks.py")
    with tempfile.TemporaryDirectory() as home:
        env = {**os.environ, "HOME": home, "VIBEBUDDY_CLAUDE_VERSION": "2.1.261"}
        settings = os.path.join(home, ".claude/settings.json")
        os.makedirs(os.path.dirname(settings), exist_ok=True)
        gate = os.path.join(HOOKS, "approval-hook.sh")
        open(settings, "w").write(json.dumps({"hooks": {"PreToolUse": [
            {"matcher": "*", "hooks": [{"type": "command", "command": f'"{gate}"'}]}]}}))
        r = subprocess.run([sys.executable, installer, "--install"], env=env,
                           capture_output=True, text=True)
        if r.returncode != 0:
            fails.append(f"claude legacy-gate --install exited {r.returncode}: {r.stderr}")
            return
        hooks = json.loads(open(settings).read())["hooks"]
        pre_tool = [h.get("command", "") for g in hooks.get("PreToolUse", [])
                    if g.get("matcher") != "AskUserQuestion" for h in g.get("hooks", [])]
        gate_now = [h.get("command", "") for g in hooks.get("PermissionRequest", []) for h in g.get("hooks", [])]
        if any("approval-hook.sh" in c for c in pre_tool):
            fails.append("plain --install left the legacy claude gate on PreToolUse")
        if not any("vibebuddy-forward.sh" in c for c in pre_tool):
            fails.append("legacy-gate migration did not restore the PreToolUse status forwarder")
        if not any("approval-hook.sh" in c for c in gate_now):
            fails.append("legacy-gate migration did not move the claude gate to PermissionRequest")


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
        claude_hooks = json.loads(open(os.path.join(home, ".claude/settings.json")).read()).get("hooks", {})
        claude_gate = [hook for group in claude_hooks.get("PermissionRequest", [])
                       for hook in group.get("hooks", [])]
        if not any("approval-hook.sh" in hook.get("command", "") for hook in claude_gate):
            fails.append("--approval did not add the claude approval gate on PermissionRequest")
        if any("vibebuddy-forward.sh" in hook.get("command", "") for hook in claude_gate):
            fails.append("--approval left the async claude PermissionRequest status group")
        if not all(hook.get("timeout") == 30 for hook in claude_gate
                   if "approval-hook.sh" in hook.get("command", "")):
            fails.append("claude approval gate must allow 30s for the phone round trip")
        claude_pre_tool = [hook for group in claude_hooks.get("PreToolUse", [])
                           if group.get("matcher") != "AskUserQuestion"
                           for hook in group.get("hooks", [])]
        if any("approval-hook.sh" in hook.get("command", "") for hook in claude_pre_tool):
            fails.append("claude approval gate must not sit on PreToolUse (it would hold every call)")
        question_gate = [hook for group in claude_hooks.get("PreToolUse", [])
                         if group.get("matcher") == "AskUserQuestion"
                         for hook in group.get("hooks", [])]
        if not any("approval-hook.sh" in hook.get("command", "") and hook.get("timeout") == 30
                   for hook in question_gate):
            fails.append("--approval did not add the blocking AskUserQuestion group on PreToolUse")
        if not any("vibebuddy-forward.sh" in hook.get("command", "") and hook.get("async") is True
                   for hook in claude_pre_tool):
            fails.append("--approval dropped the async claude PreToolUse status forwarder")
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
        claude_hooks = json.loads(open(os.path.join(home, ".claude/settings.json")).read()).get("hooks", {})
        claude_gate = [hook.get("command", "") for group in claude_hooks.get("PermissionRequest", [])
                       for hook in group.get("hooks", [])]
        if not any("approval-hook.sh" in command for command in claude_gate):
            fails.append("plain --install dropped the existing claude approval gate")
        if any("vibebuddy-forward.sh" in command for command in claude_gate):
            fails.append("re-install after --approval re-added the claude PermissionRequest forwarder")
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

    check_codex_hooks_feature(fails)
    check_grok_home(fails)
    check_claude_legacy_gate_migration(fails)
    check_claude_old_cli_keeps_legacy_gate(fails)
    check_claude_statusline_wrapper(fails)
    check_statusline_only(fails)

    if fails:
        print("FAIL:")
        for f in fails:
            print("  -", f)
        sys.exit(1)
    print("PASS: install idempotent, approval gates wired, uninstall clean, "
          "user hooks preserved (7 CLIs)")


if __name__ == "__main__":
    main()
