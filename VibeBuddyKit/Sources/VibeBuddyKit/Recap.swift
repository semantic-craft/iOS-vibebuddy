import Foundation

// MARK: - Recap: what ended while you were not looking

/// How a recorded round ended. A round the user stopped themselves is not
/// recorded (they know how it ended, they ended it — see `SessionReducer`).
public enum RecapEntryKind: String, Codable, Sendable {
    case completed, failed
}

/// One ended round of one session, as the Mac's `RecapLedger` recorded it.
/// Read-only on every device; no client ever creates one.
///
/// It is not a Completion notice (that is a wording decision) and not an
/// Unread result (that is one round's reading state): it is the fact that a
/// round ended, kept long enough to be reviewed later.
public struct RecapEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: RecapEntryKind
    public var sessionID: String
    /// `completed` only; the identity Mark all acknowledges round by round.
    public var completionID: String?
    public var agent: AgentKind
    public var project: String
    /// Session name or project, ≤160 characters.
    public var title: String
    /// Up to three lines, in this order when present: the summary sentence,
    /// the edit volume, the outcome. Each ≤100 characters.
    public var points: [String]
    public var endedAt: Date
    /// Derived when the snapshot is assembled: a completed round the user has
    /// acknowledged. A failed round has no reading state and is never read.
    public var isRead: Bool
    public var contentPresentation: ContentPresentation?

    public init(id: String, kind: RecapEntryKind, sessionID: String, completionID: String? = nil,
                agent: AgentKind, project: String, title: String, points: [String],
                endedAt: Date, isRead: Bool = false) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.completionID = completionID
        self.agent = agent
        self.project = project
        self.title = String(title.prefix(Self.titleLimit))
        self.points = Array(points.map { String($0.prefix(Self.pointLimit)) }.prefix(Self.pointsLimit))
        self.endedAt = endedAt
        self.isRead = isRead
    }

    public static let titleLimit = 160
    public static let pointLimit = 100
    public static let pointsLimit = 3

    /// The identity of a completed round is the one every other surface uses.
    public static func completedID(sourceID: String, sessionID: String, completionID: String) -> String {
        sourceID + "/" + sessionID + "/" + completionID
    }

    /// A failed round has no completion id; the moment it failed is its identity.
    public static func failedID(sourceID: String, sessionID: String, statusSince: Date) -> String {
        sourceID + "/" + sessionID + "/failed/" + String(Int64((statusSince.timeIntervalSince1970 * 1000).rounded()))
    }

    /// The edit-volume line, from the same observed tool evidence the Mac and
    /// iPhone show. Nil when nothing was observed.
    public static func ledgerLine(for session: AgentSession) -> String? {
        let files = session.changedFiles?.count ?? 0
        let commands = session.commandsRun ?? 0
        let added = session.linesAdded ?? 0
        let removed = session.linesRemoved ?? 0
        guard files > 0 || commands > 0 || added > 0 || removed > 0 else { return nil }
        var line = "\(files) files · \(commands) commands"
        if added > 0 || removed > 0 { line += " · +\(added) −\(removed)" }
        return line
    }
}

/// The recap the wrist reads: what ended after the horizon, within a day,
/// newest first, bounded.
public struct Recap: Codable, Equatable, Sendable {
    /// The moment the user last confirmed a recap (Mark all). Nil: never.
    public var horizon: Date?
    public var entries: [RecapEntry]

    public init(horizon: Date? = nil, entries: [RecapEntry] = []) {
        self.horizon = horizon
        self.entries = entries
    }

    public static let maxEntries = 12
    public static let window: TimeInterval = 24 * 60 * 60

    /// The window rule, in one place: entries that ended after both the
    /// horizon and the start of the window, newest first, at most
    /// `maxEntries`. Callers filter for source and mute before composing.
    public static func compose(entries: [RecapEntry], horizon: Date?, now: Date) -> Recap {
        var floor = now.addingTimeInterval(-window)
        if let horizon, horizon > floor { floor = horizon }
        let kept = entries
            .filter { $0.endedAt > floor }
            .sorted { $0.endedAt == $1.endedAt ? $0.id > $1.id : $0.endedAt > $1.endedAt }
            .prefix(maxEntries)
        return Recap(horizon: horizon, entries: Array(kept))
    }

    public var unreadCount: Int { entries.filter { !$0.isRead }.count }
    public var failedCount: Int { entries.filter { $0.kind == .failed }.count }
}

/// Mark all's request to the Mac: move the horizon forward. Never backward,
/// and never a change to any round's read state — clients acknowledge rounds
/// through the existing exact-round read.
public struct RecapReadRequest: Codable, Equatable, Sendable {
    public let sourceID: String
    /// The newest entry the recap showed, not the moment of the tap.
    public let horizon: Date
    public init(sourceID: String, horizon: Date) {
        self.sourceID = sourceID
        self.horizon = horizon
    }
}

/// What `POST /recap-read` said. `accepted` covers both "moved" and "already
/// there": a retried Mark all is not an error. `sourceMismatch` is definitive
/// (the request names another Mac); `failed` covers delivery or durable-write
/// failure and leaves the exact request available for retry.
public enum RecapReadOutcome: String, Codable, Sendable {
    case accepted, sourceMismatch, failed
}
