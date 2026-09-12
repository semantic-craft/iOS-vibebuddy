import Foundation
import VibeBuddyKit

/// Archive metadata never grants live control or starts a process.
public enum HistoryResumePolicy {
    public static func liveSession(for history: SessionHistorySession, in sessions: [AgentSession]) -> AgentSession? {
        guard history.projectPath.hasPrefix("/"), !history.nativeSessionID.isEmpty else { return nil }
        let matches = sessions.filter {
            $0.id == history.nativeSessionID &&
            $0.agent == (history.agent == .claude ? .claudeCode : .codex) &&
            $0.terminalRef?.cwd == history.projectPath
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A command for explicit copying only. Codex archive records currently do
    /// not establish CLI versus Desktop provenance, so they have no command.
    public static func command(for history: SessionHistorySession, directoryExists: Bool) -> String? {
        guard history.agent == .claude, history.isAvailable, directoryExists,
              UUID(uuidString: history.nativeSessionID) != nil,
              history.projectPath.hasPrefix("/"),
              !history.projectPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return "cd -- \(quote(history.projectPath)) && claude --resume \(quote(history.nativeSessionID))"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
