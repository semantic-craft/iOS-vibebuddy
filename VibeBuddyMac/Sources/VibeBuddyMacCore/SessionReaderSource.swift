import Foundation
import VibeBuddyKit

/// Where the reading pane's conversation body comes from for one session
/// (ADR-0024). Identity is exact: a live session's id *is* the agent's native
/// session id, and the transcript key is that id under the agent's key name.
/// Neither a matching title nor "the latest record" ever stands in for it.
public enum SessionReaderSource: Equatable, Sendable {
    /// The agent's own local transcript, read by `SessionTranscriptReader`
    /// by key (`claude-code:<id>`), straight from the source file.
    case transcript(key: String)
    /// The daemon's bounded recent-output excerpt — the only body for agents
    /// with no readable transcript. Never described as full history.
    case recentOutput

    /// The `readTranscript(key:)` key for a live session, or nil when no
    /// transcript reader covers the agent or the id is not a native session id.
    public static func transcriptKey(for session: AgentSession) -> String? {
        HistoryIdentity.transcriptKey(for: session)
    }

    public static func resolve(for session: AgentSession) -> SessionReaderSource {
        transcriptKey(for: session).map { .transcript(key: $0) } ?? .recentOutput
    }
}

/// The reading pane's visible slice of a transcript, anchored at the end:
/// the newest page first, earlier pages on request. Pure, so the "from the
/// end" rule and the append detection can be checked without a view.
public struct ReaderWindow: Equatable, Sendable {
    public static let pageSize = 30
    /// First visible row index.
    public var start: Int
    /// Total rows the window was computed against.
    public var count: Int

    public init(start: Int, count: Int) {
        self.count = max(0, count)
        self.start = min(max(0, start), self.count)
    }

    public var range: Range<Int> { start..<count }
    public var hasEarlier: Bool { start > 0 }

    /// The last page.
    public static func tail(of count: Int, pageSize: Int = pageSize) -> ReaderWindow {
        ReaderWindow(start: count - pageSize, count: count)
    }

    /// The window that shows `index` (a search hit) and everything after it,
    /// so the hit sits at the top of the first visible page.
    public static func revealing(_ index: Int, of count: Int) -> ReaderWindow {
        ReaderWindow(start: index, count: count)
    }

    /// One more page of earlier rows.
    public func expandedEarlier(pageSize: Int = pageSize) -> ReaderWindow {
        ReaderWindow(start: start - pageSize, count: count)
    }

    /// The same start against a transcript that gained rows at the end.
    public func grown(to newCount: Int) -> ReaderWindow {
        ReaderWindow(start: start, count: newCount)
    }

    /// How many rows were appended when `new` extends `old` in place; nil when
    /// the transcript changed in some other way and the window must reset.
    public static func appendedCount(old: [String], new: [String]) -> Int? {
        guard new.count >= old.count, new.prefix(old.count).elementsEqual(old) else { return nil }
        return new.count - old.count
    }
}
