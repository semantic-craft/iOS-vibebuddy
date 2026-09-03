// VibeBuddy OpenCode plugin — reports OpenCode lifecycle events to the local
// daemon in the Claude-Code hook shape. Edge-normalized (OpenCode has its own
// typed event runtime). Fail-open: every POST is best-effort and never throws,
// so a down daemon never blocks OpenCode.
//
// Install: copy to ~/.config/opencode/plugins/vibebuddy.js (auto-loaded at startup).

import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const PORT = process.env.VIBEBUDDY_PORT || "9876";
const HOOK_URL = `http://127.0.0.1:${PORT}/hook?agent=opencode`;
const TERM_URL = `http://127.0.0.1:${PORT}/terminal`;
const TIMEOUT_MS = 1500;

// /hook and /terminal are bearer-token gated (daemon-security/01). Read the
// daemon's token once at load; no token → request 401s, swallowed (fail-open).
const TOKEN = (() => {
  try {
    return (process.env.VIBEBUDDY_TOKEN
      || readFileSync(`${homedir()}/Library/Application Support/vibebuddy/token`, "utf8")).trim();
  } catch {
    return "";
  }
})();

async function post(url, body) {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
    await fetch(url, {
      method: "POST",
      headers: TOKEN
        ? { "content-type": "application/json", authorization: `Bearer ${TOKEN}` }
        : { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    }).catch(() => {});
    clearTimeout(t);
  } catch {
    /* fail-open: never throw out of a hook */
  }
}

function sendHook(name, fields) {
  return post(HOOK_URL, { hook_event_name: name, ...fields });
}

// OpenCode plugins run inside the OpenCode process itself, which *is* the child
// of the terminal, so the environment here is the real one — no ancestor walk is
// needed (unlike `hooks/capture-terminal.sh`, which runs in a stripped hook
// process). What this cannot see is the host app's bundle id or Ghostty's
// terminal id; those need a process-tree walk and an AppleScript round trip,
// which the shell hook does for the CLIs that have one.
function sendTerminal(sessionId, env) {
  const e = env || {};
  const tty = (e.TTY || e.SSH_TTY || "").replace(/^\/dev\//, "");
  // $ITERM_SESSION_ID is "w0t0p0:UUID"; only the UUID half is an iTerm2 session's
  // `unique ID`.
  const iterm = (e.ITERM_SESSION_ID || "").split(":").pop();
  return post(TERM_URL, {
    session_id: sessionId || "",
    term_program: e.TERM_PROGRAM || (e.KITTY_WINDOW_ID || e.TERM === "xterm-kitty" ? "kitty" : ""),
    tty,
    tmux: e.TMUX || "",
    tmux_pane: e.TMUX_PANE || "",
    iterm_session_id: iterm,
    wezterm_pane: e.WEZTERM_PANE || "",
    kitty_window_id: e.KITTY_WINDOW_ID || "",
    kitty_listen_on: e.KITTY_LISTEN_ON || "",
    cwd: e.PWD || "",
  });
}

export const VibeBuddy = async ({ directory }) => {
  const cwd = directory || process.cwd();
  const env = process.env;
  const seen = new Set();

  async function ensureStarted(sessionId) {
    if (!sessionId || seen.has(sessionId)) return;
    seen.add(sessionId);
    await sendHook("SessionStart", { session_id: sessionId, cwd });
    await sendTerminal(sessionId, env);
  }

  return {
    // SessionStart / Stop / SessionEnd come from the global event stream.
    event: async ({ event }) => {
      const t = event && event.type;
      const p = (event && event.properties) || {};
      try {
        if (t === "session.created") {
          const info = p.info || {};
          const sid = info.id || "";
          seen.add(sid);
          await sendHook("SessionStart", { session_id: sid, cwd: info.directory || cwd });
          await sendTerminal(sid, env);
        } else if (t === "session.idle") {
          await sendHook("Stop", { session_id: p.sessionID || "", cwd });
        } else if (t === "session.deleted") {
          const info = p.info || {};
          await sendHook("SessionEnd", { session_id: info.id || "", cwd: info.directory || cwd });
        } else if (t === "session.error") {
          await sendHook("Stop", { session_id: p.sessionID || "", cwd, message: (p.error && p.error.name) || "session.error" });
        }
      } catch {
        /* fail-open */
      }
    },

    // UserPromptSubmit
    "chat.message": async (input, output) => {
      const sid = (input && input.sessionID) || "";
      await ensureStarted(sid);
      let text = "";
      try {
        const parts = (output && output.parts) || [];
        text = parts.filter((x) => x && x.type === "text" && typeof x.text === "string").map((x) => x.text).join("\n");
      } catch {
        /* ignore */
      }
      await sendHook("UserPromptSubmit", { session_id: sid, cwd, message: text });
    },

    // PreToolUse
    "tool.execute.before": async (input) => {
      const sid = (input && input.sessionID) || "";
      await ensureStarted(sid);
      await sendHook("PreToolUse", { session_id: sid, cwd, tool_name: (input && input.tool) || "" });
    },

    // PostToolUse (is_error best-effort: OpenCode's after-hook has no error flag)
    "tool.execute.after": async (input, output) => {
      const sid = (input && input.sessionID) || "";
      let isError = false;
      try {
        const md = (output && output.metadata) || {};
        const out = (output && output.output) || "";
        isError = Boolean(md.error) || /(^|\b)(error|failed|exception)\b/i.test(String(out).slice(0, 200));
      } catch {
        /* default false */
      }
      await sendHook("PostToolUse", { session_id: sid, cwd, tool_name: (input && input.tool) || "", tool_response: { is_error: isError } });
    },
  };
};
