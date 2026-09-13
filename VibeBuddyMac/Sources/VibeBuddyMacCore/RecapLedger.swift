import Foundation
import VibeBuddyKit

/// The Mac's record of ended rounds — the recap's only source of truth.
///
/// A session carries one completion at a time and a failure until its next
/// turn, so without this file a round the user did not look at in time is
/// simply gone. The ledger keeps one entry per ended round for seven days,
/// plus the **recap horizon**: the moment the user last confirmed a recap
/// (Mark all). It observes sessions rather than events, so every observation
/// path (hooks, app-server, Cursor) records the same way, and observing twice
/// records nothing new.
///
/// Persisted like `CompletionNoticeLedger`: owner-only JSON, atomic writes,
/// unavailable storage degrades to memory for this process only.
struct RecapLedger {
    /// What is kept per round. The summary sentence is looked up at snapshot
    /// time from the notice ledger (a notice settles up to twelve seconds after
    /// the round ends); `fallbackSummary` stands in when there is none.
    struct Stored: Codable, Equatable, Sendable {
        var id: String
        var kind: RecapEntryKind
        var sessionID: String
        var completionID: String?
        var agent: AgentKind
        var project: String
        var title: String
        var fallbackSummary: String?
        var ledgerLine: String?
        var endedAt: Date
        var recordedAt: Date
    }

    struct File: Codable, Equatable, Sendable {
        var horizon: Date?
        var entries: [String: Stored]
    }

    static let retention: TimeInterval = 7 * 86_400

    let url: URL?
    private(set) var horizon: Date?
    private(set) var entries: [String: Stored]
    private var available = true
    /// Only rounds observed running/waiting in this process can add entries.
    /// Initial app-server status and journal recovery describe existing endings,
    /// not endings observed now. This set deliberately does not survive restart.
    private var liveRounds: Set<String> = []

    init(url: URL?, now: Date = Date()) {
        self.url = url
        horizon = nil
        entries = [:]
        guard let url else { return }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            horizon = file.horizon
            entries = file.entries.filter { $0.value.endedAt > now.addingTimeInterval(-Self.retention) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        } catch {
            available = false
        }
    }

    // MARK: recording

    /// Record newly ended rounds observed live, and enrich rounds already on file.
    /// Returns whether anything new was recorded. Sessions with no completion
    /// and no failure (working, waiting, user-stopped, probe-retired) leave no
    /// trace; a session that vanished leaves what it already had.
    @discardableResult
    mutating func observe(_ sessions: [AgentSession], sourceID: String?, now: Date) -> Bool {
        guard let sourceID, !sourceID.isEmpty else { return false }
        var added = false
        liveRounds.formIntersection(sessions.map(\.id))
        for session in sessions where session.historyOnly != true {
            // A tool may fail while the agent continues recovering. `isStuck`
            // alone is also true in that working state; it is not an ending.
            guard session.status == .done else {
                liveRounds.insert(session.id)
                continue
            }
            let observedLive = liveRounds.remove(session.id) != nil
            if session.isStuck {
                let id = RecapEntry.failedID(sourceID: sourceID, sessionID: session.id, statusSince: session.statusSince)
                if entries[id] == nil, observedLive {
                    entries[id] = Stored(id: id, kind: .failed, sessionID: session.id, completionID: nil,
                                         agent: session.agent, project: session.project,
                                         title: Self.title(of: session),
                                         fallbackSummary: Self.sentence(session.summary),
                                         ledgerLine: RecapEntry.ledgerLine(for: session),
                                         endedAt: session.statusSince, recordedAt: now)
                    added = true
                }
            } else if session.status == .done, let completionID = session.completionID, !completionID.isEmpty {
                let id = RecapEntry.completedID(sourceID: sourceID, sessionID: session.id, completionID: completionID)
                if var existing = entries[id] {
                    // The final text can arrive after the round ended (the
                    // Claude reader, a labelled Codex duplicate); fill the
                    // sentence in once, never replace one already kept.
                    if existing.fallbackSummary == nil, let sentence = Self.sentence(session.completionText) {
                        existing.fallbackSummary = sentence
                        entries[id] = existing
                        added = true
                    }
                } else if observedLive {
                    entries[id] = Stored(id: id, kind: .completed, sessionID: session.id, completionID: completionID,
                                         agent: session.agent, project: session.project,
                                         title: Self.title(of: session),
                                         fallbackSummary: Self.sentence(session.completionText ?? session.summary),
                                         ledgerLine: RecapEntry.ledgerLine(for: session),
                                         endedAt: session.statusSince, recordedAt: now)
                    added = true
                }
            }
        }
        if added { save(now: now) }
        return added
    }

    /// Move the horizon forward. Returns whether it moved; an older or equal
    /// horizon is a no-op, which is what makes a retried Mark all harmless.
    @discardableResult
    mutating func advanceHorizon(to date: Date, now: Date) -> Bool {
        if let horizon, horizon >= date { return false }
        horizon = date
        save(now: now)
        return true
    }

    // MARK: reading

    /// The recap for this moment. `sessions` is the snapshot's own list, so
    /// muting and acknowledgement are read from the same facts every other
    /// surface uses; `summary` resolves a completed round's notice by its id.
    func recap(now: Date, sessions: [AgentSession], summary: (String) -> String?) -> Recap {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = entries.values.compactMap { stored -> RecapEntry? in
            let session = byID[stored.sessionID]
            if session?.effectiveAttention == .muted { return nil }
            var points: [String] = []
            if let line = (stored.kind == .completed ? summary(stored.id) : nil) ?? stored.fallbackSummary {
                points.append(line)
            }
            if let ledger = stored.ledgerLine { points.append(ledger) }
            let read = stored.kind == .completed && stored.completionID != nil
                && session?.acknowledgedCompletionID == stored.completionID
            return RecapEntry(id: stored.id, kind: stored.kind, sessionID: stored.sessionID,
                              completionID: stored.completionID, agent: stored.agent, project: stored.project,
                              title: stored.title, points: points, endedAt: stored.endedAt, isRead: read)
        }
        return Recap.compose(entries: visible, horizon: horizon, now: now)
    }

    // MARK: helpers

    private static func title(of session: AgentSession) -> String {
        let title = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Unnamed task" : title
    }

    private static func sentence(_ text: String?) -> String? {
        guard let text = RowPresentation.firstSentence(text)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return String(text.prefix(RecapEntry.pointLimit))
    }

    private mutating func save(now: Date) {
        entries = entries.filter { $0.value.endedAt > now.addingTimeInterval(-Self.retention) }
        guard let url, available else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(File(horizon: horizon, entries: entries))
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Memory keeps this process honest; the next launch starts from the last good file.
        }
    }
}
