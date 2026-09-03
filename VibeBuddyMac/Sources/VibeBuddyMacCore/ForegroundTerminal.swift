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
    /// Bundle identifiers a given `TERM_PROGRAM` is known to run under. The one
    /// table for the mapping — `TerminalJumper` reads it too, to decide which app
    /// a jump should bring forward.
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

    /// Every bundle id a ref could be running under: the captured host bundle id
    /// (exact, from process ancestry) plus whatever its `TERM_PROGRAM` implies.
    /// Both are needed — a session inside an embedded terminal has only the
    /// former, and a session under tmux, whose server has no GUI ancestor, has
    /// only the latter.
    static func bundleIDs(for ref: TerminalRef) -> [String] {
        let fromTermProgram = ref.termProgram.map { bundleIDs(forTermProgram: $0) } ?? []
        guard let host = ref.hostBundleId else { return fromTermProgram }
        return [host] + fromTermProgram
    }

    /// The sessions whose terminal app is `frontmostBundleID`. Empty when nothing
    /// matches — a non-terminal app is frontmost, the terminal is unknown, or no
    /// session reported a terminal.
    public static func focusedSessionIDs(among sessions: [AgentSession],
                                         frontmostBundleID: String?) -> Set<String> {
        guard let front = frontmostBundleID else { return [] }
        return Set(
            sessions
                .filter { ($0.terminalRef.map { bundleIDs(for: $0) } ?? []).contains(front) }
                .map(\.id)
        )
    }
}
