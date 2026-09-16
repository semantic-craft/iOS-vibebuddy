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
        /// The round's own read mark, kept here because a session carries only
        /// its latest completion's read state: once the session moves on, this
        /// is the only record that an earlier round was read (or put back to
        /// unread). Absent in files written before it existed.
        var isRead: Bool?
        var resultText: String?
        var resultConflict: Bool?
    }

    struct File: Codable, Equatable, Sendable {
        var horizon: Date?
        var entries: [String: Stored]
        var results: [String: CompletionResults.Record]? = nil
    }

    static let maximumResults = 512
    static let maximumResultBytes = 8 * 1_024 * 1_024
    static let maximumFileBytes = 32 * 1_024 * 1_024

    static let retention: TimeInterval = 7 * 86_400

    let url: URL?
    private(set) var horizon: Date?
    private(set) var entries: [String: Stored]
    private(set) var results: [String: CompletionResults.Record] = [:]
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
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumFileBytes else { available = false; return }
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            results = Self.bounded(file.results ?? [:], now: now)
            horizon = file.horizon
            entries = file.entries.filter { $0.value.endedAt > now.addingTimeInterval(-Self.retention) }
        } catch {
            let failure = error as NSError
            // URL resource APIs can throw NSError without a CocoaError cast.
            // A missing new ledger is writable; other load failures stay closed.
            available = failure.domain == NSCocoaErrorDomain
                && failure.code == CocoaError.fileReadNoSuchFile.rawValue
        }
    }

    // MARK: recording

    /// Record newly ended rounds observed live, and enrich rounds already on file.
    /// Returns whether anything new was recorded. Sessions with no completion
    /// and no failure (working, waiting, user-stopped, probe-retired) leave no
    /// trace; a session that vanished leaves what it already had.
    @discardableResult
    mutating func observe(_ sessions: [AgentSession], sourceID: String?, now: Date,
                          results: [String: String] = [:]) -> Bool {
        guard let sourceID, !sourceID.isEmpty else { return false }
        var changed = false
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
                    entries[id]?.resultText = session.summary.map { String($0.prefix(12_000)) }
                    changed = true
                }
            } else if session.status == .done, let completionID = session.completionID, !completionID.isEmpty {
                let id = RecapEntry.completedID(sourceID: sourceID, sessionID: session.id, completionID: completionID)
                if var existing = entries[id] {
                    if let result = results[id], existing.resultText != result {
                        if existing.resultText == nil { existing.resultText = String(result.prefix(12_000)) }
                        else { existing.resultConflict = true }
                        changed = true
                    }
                    // The final text can arrive after the round ended (the
                    // Claude reader, a labelled Codex duplicate); fill the
                    // sentence in once, never replace one already kept.
                    if existing.fallbackSummary == nil, let sentence = Self.sentence(session.completionText) {
                        existing.fallbackSummary = sentence
                        changed = true
                    }
                    // While this is the session's current round, its read mark
                    // follows the session (read, then Mark Unread, then read
                    // again); the last value observed is what the entry keeps
                    // once a later round replaces it.
                    if let read = Self.readState(of: existing, in: session), existing.isRead != read {
                        existing.isRead = read
                        changed = true
                    }
                    entries[id] = existing
                } else if observedLive {
                    var stored = Stored(id: id, kind: .completed, sessionID: session.id, completionID: completionID,
                                        agent: session.agent, project: session.project,
                                        title: Self.title(of: session),
                                        fallbackSummary: Self.sentence(session.completionText ?? session.summary),
                                        ledgerLine: RecapEntry.ledgerLine(for: session),
                                        endedAt: session.statusSince, recordedAt: now)
                    stored.isRead = Self.readState(of: stored, in: session)
                    stored.resultText = results[id].map { String($0.prefix(12_000)) }
                    entries[id] = stored
                    changed = true
                }
            }
        }
        if changed { save(now: now) }
        return changed
    }

    /// Move the horizon forward. Returns whether it moved; an older or equal
    /// horizon is a no-op, which is what makes a retried Mark all harmless.
    /// A configured but unavailable durable store rejects explicit confirmation.
    @discardableResult
    mutating func advanceHorizon(to date: Date, now: Date) throws -> Bool {
        if let horizon, horizon >= date { return false }
        var candidate = self
        candidate.horizon = date
        guard candidate.save(now: now) else { throw CocoaError(.fileWriteUnknown) }
        self = candidate
        return true
    }

    // MARK: reading

    static func bounded(_ records: [String: CompletionResults.Record], now: Date) -> [String: CompletionResults.Record] {
        var bytes = 0
        var kept: [String: CompletionResults.Record] = [:]
        for record in records.values.sorted(by: {
            $0.completedAt == $1.completedAt ? $0.id < $1.id : $0.completedAt > $1.completedAt
        }) where record.completedAt > now.addingTimeInterval(-retention) {
            guard kept.count < maximumResults else { break }
            guard records[record.id] == record, !record.sourceID.isEmpty, !record.sessionID.isEmpty,
                  !record.completionID.isEmpty, record.completedAt >= (record.startedAt ?? .distantPast),
                  record.agent != .codex || record.turnID?.isEmpty == false,
                  record.text.map({ $0.count <= 12_000 }) ?? true,
                  let data = try? JSONEncoder().encode(record), bytes + data.count <= maximumResultBytes else { continue }
            bytes += data.count
            kept[record.id] = record
        }
        return kept
    }

    mutating func retainResults(_ records: [String: CompletionResults.Record], now: Date) {
        let next = Self.bounded(records, now: now)
        guard next != results else { return }
        results = next
        for (id, record) in results where entries[id] != nil {
            if record.conflict || record.invalidated { entries[id]?.resultConflict = true }
            if let text = record.text { retainResultInMemory(id: id, text: text) }
        }
        save(now: now)
    }

    mutating func retainResult(id: String, text: String, now: Date) {
        guard entries[id]?.endedAt ?? .distantPast > now.addingTimeInterval(-Self.retention) else { return }
        retainResultInMemory(id: id, text: text)
        save(now: now)
    }

    private mutating func retainResultInMemory(id: String, text: String) {
        guard var entry = entries[id], !text.isEmpty, text.count <= 12_000 else { return }
        if let first = entry.resultText, first != text { entry.resultConflict = true }
        else { entry.resultText = text }
        entries[id] = entry
    }

    /// The recap for this moment. `sessions` is the snapshot's own list, so
    /// muting and acknowledgement are read from the same facts every other
    /// surface uses; `summary` resolves a completed round's notice by its id.
    func recap(now: Date, sessions: [AgentSession], summary: (String) -> String?) -> Recap {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = entries.values.compactMap { stored -> RecapEntry? in
            let session = byID[stored.sessionID]
            if session?.effectiveAttention == .muted { return nil }
            var points: [String] = []
            if stored.resultConflict != true,
               let line = (stored.kind == .completed ? summary(stored.id) : nil) ?? stored.fallbackSummary {
                points.append(line)
            }
            if let ledger = stored.ledgerLine { points.append(ledger) }
            // The session is authoritative for its current round; every earlier
            // round keeps the mark the ledger recorded while it was current.
            let read = Self.readState(of: stored, in: session) ?? stored.isRead ?? false
            return RecapEntry(id: stored.id, kind: stored.kind, sessionID: stored.sessionID,
                              completionID: stored.completionID, agent: stored.agent, project: stored.project,
                              title: stored.title, points: points, endedAt: stored.endedAt, isRead: read)
        }
        return Recap.compose(entries: visible, horizon: horizon, now: now)
    }

    // MARK: helpers

    /// The session's own read mark for a completed round, or nil when this
    /// round is not the one the session currently carries. Read means
    /// acknowledged and not put back to unread: `markCompletionUnread` keeps
    /// `acknowledgedCompletionID` and raises `hasUnreadCompletion`.
    private static func readState(of stored: Stored, in session: AgentSession?) -> Bool? {
        guard stored.kind == .completed, let completionID = stored.completionID,
              let session, session.completionID == completionID else { return nil }
        return session.acknowledgedCompletionID == completionID && !session.hasUnreadCompletion
    }

    private static func title(of session: AgentSession) -> String {
        let title = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Unnamed task" : title
    }

    private static func sentence(_ text: String?) -> String? {
        guard let text = RowPresentation.firstSentence(text)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return String(text.prefix(RecapEntry.pointLimit))
    }

    @discardableResult
    private mutating func save(now: Date) -> Bool {
        entries = entries.filter { $0.value.endedAt > now.addingTimeInterval(-Self.retention) }
        results = Self.bounded(results, now: now)
        guard let url else { return true }
        guard available else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(File(horizon: horizon, entries: entries, results: results))
            // macOS supports owner-only files here; completeFileProtection can
            // reject mktemp with EPERM. Keep atomic replacement inside the 0700 directory.
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            return false
        }
        return true
    }
}
