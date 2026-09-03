import AppKit
import VibeBuddyKit

/// The one place the Mac turns a `JumpOutcome` into words. The glance rows, the
/// glance approval card and the dashboard detail pane all read it, so a jump
/// never reports differently depending on where it was started from.
///
/// The wording promises only what happened: `.focused` means the session's own
/// pane (or, for a Codex Desktop session, its thread) came forward,
/// `.activatedApp` means we could only raise the app around it, and the two
/// failure cases say which kind of failure it was.
extension JumpOutcome {
    @MainActor
    func macMessage(for session: AgentSession) -> String {
        // A Codex Desktop session's jump lands in a ChatGPT thread, not a
        // terminal, so every outcome has to be worded for where it went.
        if session.jumpsToDesktopThread {
            switch self {
            case .focused: return "Opened thread in ChatGPT"
            case .activatedApp: return "Brought ChatGPT to front"
            case .unsupported: return "Couldn't open the thread — is ChatGPT running?"
            case .noTerminal: return "No thread recorded for this session"
            }
        }
        switch self {
        case .focused:
            return "Focused terminal"
        case .activatedApp:
            // The app's own name when macOS can tell us (it is running — that is
            // what `.activatedApp` means), otherwise the honest generic.
            if let name = session.terminalRef?.hostBundleId.flatMap(Self.runningAppName) {
                return "Brought \(name) to front"
            }
            return "Brought app to front"
        case .unsupported:
            return "Couldn't locate this session's window"
        case .noTerminal:
            return "No terminal recorded for this session"
        }
    }

    @MainActor
    private static func runningAppName(_ bundleID: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName
    }
}
