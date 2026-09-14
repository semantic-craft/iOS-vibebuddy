import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// Where a jump for this session lands, named the way the user thinks of it:
/// *terminal* for a pane or tab in a terminal emulator, otherwise the app that
/// hosts the session (Claude, Cursor, VS Code, ChatGPT / Codex Desktop). The
/// reader's jump control is an icon, so the name lives in its tooltip and
/// accessibility label; the symbol says how precisely the jump can land, the
/// same three glyphs the glance rows use.
struct JumpDestination: Equatable {
    /// `terminal` = its own pane/tab, `bubble.left` = a desktop thread,
    /// `macwindow` = only the app around it.
    let symbol: String
    /// Display name of the target — "terminal", "Claude", "Cursor", "ChatGPT".
    let name: String

    var title: String { String(localized: "Jump to \(name)") }

    @MainActor
    static func resolve(_ session: AgentSession) -> JumpDestination {
        if session.agent == .grokBot { return JumpDestination(symbol: "bubble.left", name: "Grok Bot") }
        if session.jumpsToDesktopThread {
            return JumpDestination(symbol: "bubble.left",
                                   name: appName(CodexDesktopJumper.chatGPTBundleID) ?? "ChatGPT")
        }
        guard let ref = session.terminalRef else {
            // A Cursor session or cloud agent has no ref; the route still raises Cursor.
            if session.agent == .cursor { return JumpDestination(symbol: "macwindow", name: "Cursor") }
            return JumpDestination(symbol: "terminal", name: String(localized: "terminal"))
        }
        if ref.hasExactTarget || isTerminalEmulator(ref) {
            return JumpDestination(symbol: "terminal", name: String(localized: "terminal"))
        }
        if let host = ref.hostBundleId {
            return JumpDestination(symbol: "macwindow", name: knownName[host] ?? appName(host) ?? String(localized: "app"))
        }
        return JumpDestination(symbol: "macwindow", name: String(localized: "app"))
    }

    /// Hosts whose bundle name reads worse than the name people use for them.
    private static let knownName: [String: String] = [
        "com.anthropic.claudefordesktop": "Claude",
        "com.anthropic.claude-code": "Claude",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.microsoft.VSCode": "VS Code",
    ]

    private static let terminalPrograms: Set<String> = ["apple_terminal", "iterm.app", "ghostty", "wezterm", "kitty", "warpterminal", "warp"]
    private static let terminalBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "dev.warp.Warp-Stable", "dev.warp.Warp",
    ]

    private static func isTerminalEmulator(_ ref: TerminalRef) -> Bool {
        if let host = ref.hostBundleId { return terminalBundles.contains(host) }
        if let tp = ref.termProgram?.lowercased() { return terminalPrograms.contains(tp) }
        return false
    }

    /// The app's own name: running first, then installed, else nothing.
    @MainActor
    private static func appName(_ bundleID: String) -> String? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return running
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
