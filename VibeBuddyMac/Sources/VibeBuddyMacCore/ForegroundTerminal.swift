import Foundation
import VibeBuddyKit

/// Decides which sessions the user is *currently looking at* by matching the
/// frontmost macOS app to each session's terminal. This is the precise signal
/// behind `SoundPolicyInput.focusedSessionIDs`, replacing the coarse
/// `NSApp.isActive` (which only knew whether VibeBuddy itself was frontmost).
///
/// App-level only: without the Accessibility permission we can't tell which
/// tab/window *within* a terminal is frontmost, so every session sharing the
/// frontmost terminal app counts as focused. That is intentionally conservative
/// — it silences a finishing session's cue when its terminal is on screen, and
/// at worst over-silences sibling tabs in the same app, never the reverse.
public enum ForegroundTerminal {
    /// Bundle identifiers a given `TERM_PROGRAM` is known to run under. The
    /// reverse of `TerminalJumper.appName(forTermProgram:)`; keep the two in sync.
    static func bundleIDs(forTermProgram tp: String) -> [String] {
        switch tp.lowercased() {
        case "ghostty":               return ["com.mitchellh.ghostty"]
        case "iterm.app":             return ["com.googlecode.iterm2"]
        case "apple_terminal":        return ["com.apple.Terminal"]
        case "wezterm":               return ["com.github.wez.wezterm"]
        case "warpterminal", "warp":  return ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case "kitty":                 return ["net.kovidgoyal.kitty"]
        case "vscode":                return ["com.microsoft.VSCode"]
        default:                      return []
        }
    }

    /// The sessions whose terminal app is `frontmostBundleID`. Empty when nothing
    /// matches — a non-terminal app is frontmost, the terminal is unknown, or no
    /// session reported a terminal.
    public static func focusedSessionIDs(among sessions: [AgentSession],
                                         frontmostBundleID: String?) -> Set<String> {
        guard let front = frontmostBundleID else { return [] }
        return Set(
            sessions
                .filter { ($0.terminalRef.map { bundleIDs(forTermProgram: $0.termProgram) } ?? []).contains(front) }
                .map(\.id)
        )
    }
}
