import Foundation

/// A handoff document the Mac found under a known checkout's
/// `.scratch/<feature>/handoffs/`. The file is the only truth: this is what
/// its first lines say plus where it is, so a session row can show that a
/// handoff exists and Continue with… can point a receiver at it (ADR-0023).
public struct HandoffRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Absolute path of the document; also its identity.
    public var path: String
    /// The writer's own Session key from the first line, or nil when the
    /// line says `unknown` or is not a valid key.
    public var sourceKey: String?
    public var ticket: String?
    public var branch: String?
    public var worktree: String?
    /// The file's modification time.
    public var writtenAt: Date
    /// Session keys (`<agent>:<id>`) of receivers the Mac started from this
    /// document, oldest first, from the Mac's continuation records (seven days).
    public var takenBy: [String]
    public var id: String { path }
    public init(path: String, sourceKey: String? = nil, ticket: String? = nil, branch: String? = nil,
                worktree: String? = nil, writtenAt: Date, takenBy: [String] = []) {
        self.path = path; self.sourceKey = sourceKey; self.ticket = ticket; self.branch = branch
        self.worktree = worktree; self.writtenAt = writtenAt; self.takenBy = takenBy
    }
}
