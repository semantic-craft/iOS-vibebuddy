import Foundation
import VibeBuddyKit

/// A Claude Code background session (`claude --bg`, agent view, Dispatch), as
/// the CLI's supervisor records it under `~/.claude/jobs/<id>/state.json`.
/// Read-only: vibebuddy never writes these files, never starts the supervisor,
/// and never creates or moves a session from them — they only tell a jump
/// where `claude attach <id>` lands and lend a name to a row the hooks left
/// unnamed.
public struct ClaudeBackgroundSession: Sendable, Equatable {
    /// The short job id `claude attach` takes (the directory name).
    public let id: String
    public let sessionID: String
    public let name: String?
    public let state: String?
    /// What the session is waiting on, in the supervisor's own words.
    public let needs: String?

    public init(id: String, sessionID: String, name: String? = nil, state: String? = nil, needs: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.name = name
        self.state = state
        self.needs = needs
    }
}

public enum ClaudeBackgroundSessions {
    public static func jobsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/jobs", isDirectory: true)
    }

    /// Every job with a readable `state.json`. Unreadable or malformed entries
    /// are skipped, and a missing directory is simply no sessions.
    public static func load(jobsDirectory: URL = jobsDirectory(),
                            fileManager fm: FileManager = .default) -> [ClaudeBackgroundSession] {
        guard let names = try? fm.contentsOfDirectory(atPath: jobsDirectory.path) else { return [] }
        return names.sorted().compactMap { name in
            guard isJobID(name) else { return nil }
            let state = jobsDirectory.appendingPathComponent(name).appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: state),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else { return nil }
            return ClaudeBackgroundSession(
                id: name, sessionID: sessionID,
                name: nonEmpty(object["name"] as? String),
                state: nonEmpty(object["state"] as? String),
                needs: nonEmpty(object["needs"] as? String))
        }
    }

    public static func find(sessionID: String, jobsDirectory: URL = jobsDirectory(),
                            fileManager fm: FileManager = .default) -> ClaudeBackgroundSession? {
        load(jobsDirectory: jobsDirectory, fileManager: fm).first { $0.sessionID == sessionID }
    }

    /// Job ids are short hex; nothing else may reach a shell as `claude attach <id>`.
    public static func isJobID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32
            && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
