import Foundation
import VibeBuddyKit

/// Archive metadata never grants live control or starts a process.
public enum HistoryResumePolicy {
    public static func liveSession(for history: SessionHistorySession, in sessions: [AgentSession]) -> AgentSession? {
        guard history.projectPath.hasPrefix("/"), !history.nativeSessionID.isEmpty else { return nil }
        let matches = sessions.filter {
            guard $0.id == history.nativeSessionID,
                  $0.agent == agentKind(history.agent) else { return false }
            if let cwd = $0.terminalRef?.cwd { return cwd == history.projectPath }
            // Daemon/desktop observations have a verified thread identity but
            // need not have a terminal. Keep using the live action capability;
            // this does not establish CLI provenance or invent a resume command.
            return history.agent == .codex && $0.desktopThreadID == history.nativeSessionID
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Copying never invokes an agent. Only explicit CLI provenance can supply
    /// a Codex terminal command; Desktop and child sessions keep their own route.
    public static func command(for history: SessionHistorySession, directoryExists: Bool) -> String? {
        guard (history.agent == .claude || history.agent == .grokBuild || (history.agent == .codex && history.source == "cli")),
              history.sourceArchived != true, history.isAvailable, directoryExists,
              UUID(uuidString: history.nativeSessionID) != nil,
              history.projectPath.hasPrefix("/"),
              !history.projectPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let command: String
        switch history.agent {
        case .claude: command = "claude --resume"
        case .codex: command = "codex resume"
        case .grokBuild: command = "grok --resume"
        }
        return "cd -- \(quote(history.projectPath)) && \(command) \(quote(history.nativeSessionID))"
    }

    private static func agentKind(_ agent: SessionHistoryAgent) -> AgentKind {
        switch agent { case .claude: .claudeCode; case .codex: .codex; case .grokBuild: .grok }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
