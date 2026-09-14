import Foundation
import VibeBuddyKit

/// Continue with… (ADR-0023 §4): the receiver's first prompt, composed the
/// way the `handoff` skill says a receiver should be started — pointed at the
/// document's path, never handed the summary — plus the `Continues:` line
/// that names the session being continued. Pure, so the Mac sheet and a
/// future phone entry compose the same text.
public enum ContinueWith {
    /// The Session key of a live session as the history tools name it, or nil
    /// for agents the history side does not know (no handoff can name them).
    public static func sessionKey(for session: AgentSession) -> String? {
        sessionKey(agent: session.agent, id: session.id)
    }

    /// The same key for a session the Mac just started and has not yet observed.
    public static func sessionKey(agent: AgentKind, id: String) -> String? {
        switch agent {
        case .claudeCode: "claude-code:" + id
        case .codex: "codex:" + id
        case .cursor: "cursor:" + id
        case .grok: "grok-build:" + id
        default: nil
        }
    }

    /// The newest handoff record whose `Source session` is this session.
    public static func handoff(for session: AgentSession, in records: [HandoffRecord]) -> HandoffRecord? {
        guard let key = sessionKey(for: session) else { return nil }
        return records.filter { $0.sourceKey == key }.max { $0.writtenAt < $1.writtenAt }
    }

    public static func prompt(sessionKey: String, handoffPath: String?, checkout: String? = nil) -> String {
        let reference = "vibebuddy://session/" + sessionKey
        if let handoffPath {
            let text = "Read \(handoffPath), then continue.\nContinues: \(reference)"
            return promptForDispatch(text, handoffPath: handoffPath, checkout: checkout)
        }
        return "Continues: \(reference)\nNo handoff document was written for it. Read it first: `vibebuddy-mcp facts '\(sessionKey)'` for what was recorded, `vibebuddy-mcp show '\(sessionKey)'` for the conversation."
    }

    /// Recompute only our generated fallback, preserving the person's prompt edits.
    public static func promptForDispatch(_ text: String, handoffPath: String?, checkout: String?) -> String {
        guard let handoffPath else { return text }
        let root = URL(fileURLWithPath: handoffPath).resolvingSymlinksInPath().standardizedFileURL
            .deletingLastPathComponent().deletingLastPathComponent().path
        let fallback = "The handoff lives in \(root), outside this checkout; if your sandbox refuses to write there, report the text instead of writing."
        let base = text.components(separatedBy: "\n").filter { $0 != fallback }.joined(separator: "\n")
        guard let checkout, !checkout.isEmpty, writableRoot(handoffPath: handoffPath, cwd: checkout) != nil else { return base }
        return base + "\n" + fallback
    }

    /// The effort directory a Codex receiver needs to write in: the handoff's
    /// `.scratch/<feature>/` (parent of `handoffs/`), symlinks resolved. Nil
    /// when that directory is inside the checkout already, so nothing needs
    /// to be granted, or when the path is not a handoff path.
    public static func writableRoot(handoffPath: String, cwd: String) -> String? {
        let resolved = URL(fileURLWithPath: handoffPath).resolvingSymlinksInPath().standardizedFileURL
        let handoffs = resolved.deletingLastPathComponent()
        guard handoffs.lastPathComponent == "handoffs" else { return nil }
        let effort = handoffs.deletingLastPathComponent()
        guard effort.deletingLastPathComponent().lastPathComponent == ".scratch" else { return nil }
        let checkout = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        let root = effort.path
        if root == checkout || root.hasPrefix(checkout.hasSuffix("/") ? checkout : checkout + "/") { return nil }
        return root
    }

    public static func taskName(for session: AgentSession) -> String {
        let title = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Continue: " + (title.isEmpty ? session.project : String(title.prefix(60)))
    }

    /// Other sessions currently busy in the same checkout — a hint for the
    /// sheet, never a lock (ADR-0019).
    public static func busySessions(in directory: String, among sessions: [AgentSession], excluding sessionID: String?) -> [AgentSession] {
        let target = URL(fileURLWithPath: directory).standardizedFileURL.path
        return sessions.filter { session in
            session.id != sessionID && session.historyOnly != true
                && (session.status == .working || session.status == .needsResponse)
                && [session.checkoutPath, session.terminalRef?.cwd].compactMap { $0 }
                    .contains { URL(fileURLWithPath: $0).standardizedFileURL.path == target }
        }
    }
}
