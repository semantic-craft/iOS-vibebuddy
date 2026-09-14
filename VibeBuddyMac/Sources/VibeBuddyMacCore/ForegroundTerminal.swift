import Foundation
import VibeBuddyKit

/// Matches sessions to the frontmost terminal app for approval routing and
/// optional source-app speech suppression. This is app-level presence only:
/// it cannot identify the selected tab and must not be used as proof that a
/// task is being viewed when deciding phone/watch notification delivery.
public enum ForegroundTerminal {
    /// Grok Bot exposes app-level presence, not the selected bot. This is only
    /// a speech suppression signal: never treat all bots as viewed or read.
    public static func sourceAppSuppressesSpeech(for session: AgentSession,
                                                 frontmostBundleID: String?) -> Bool {
        session.agent == .grokBot && frontmostBundleID == GrokBotJumper.bundleID
    }

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
