import Foundation
import VibeBuddyKit

/// Extraction evidence stays out of snapshots and the lifecycle journal.
/// The recap ledger retains a bounded copy of verified finalText by exact round.
public struct FrozenCompletionResult: Sendable, Equatable {
    public let sourceID: String
    public let sessionID: String
    public let completionID: String
    public let turnID: String?
    public let title: String
    public let finalText: String
    public let completedAt: Date
    public let observedAt: Date
}

public enum CompletionResultAvailability: Sendable, Equatable {
    case ready(FrozenCompletionResult)
    case resultUnavailable
    case resultTooLong
    case cancelled
    case expired
}

/// Separate from progress: failure to prove a result never changes the three states.
struct CompletionResults {
    /// Persisted independently of recap entries. Native identity or an observed
    /// Claude prompt boundary is required; the opaque completion UUID is never guessed.
    struct Record: Codable, Equatable, Sendable {
        let sourceID: String
        let sessionID: String
        let completionID: String
        let agent: AgentKind
        let turnID: String?
        let title: String
        var startedAt: Date?
        let completedAt: Date
        var transcriptPath: String?
        var transcriptOffset: UInt64? = nil
        var text: String?
        var conflict = false
        var invalidated = false
        var id: String { RecapEntry.completedID(sourceID: sourceID, sessionID: sessionID, completionID: completionID) }
        func readable(now: Date) -> Bool {
            !conflict && !invalidated && completedAt > now.addingTimeInterval(-RecapLedger.retention)
        }
        func frozen(now: Date) -> FrozenCompletionResult? {
            guard readable(now: now), let text, !text.isEmpty, text.count <= 12_000 else { return nil }
            return .init(sourceID: sourceID, sessionID: sessionID, completionID: completionID,
                turnID: turnID, title: title, finalText: text, completedAt: completedAt, observedAt: now)
        }
    }
    private struct Run {
        let agent: AgentKind
        let startedAt: Date
        let turnID: String?
        var transcriptPath: String? = nil
        var transcriptOffset: UInt64? = nil
    }
    private struct Candidate: Sendable {
        let completionID: String
        let turnID: String?
        let title: String
        let completedAt: Date
        let transcriptPath: String?
        var expectedText: String?
        var outcome: CompletionResultAvailability?
        var readingResult: FrozenCompletionResult?
    }
    private var runs: [String: Run] = [:]
    private var candidates: [String: Candidate] = [:]
    private var records: [String: Record] = [:]

    init(restoring ledger: RecapLedger? = nil) {
        records = ledger?.results ?? [:]
    }

    mutating func removeSession(_ id: String) {
        runs[id] = nil
        candidates[id] = nil
    }

    mutating func retain(in ledger: inout RecapLedger, now: Date) -> [String] {
        // Runs on every ingested event. `bounded` JSON-encodes every record
        // to size the set, and the ledger's results are always a bounded set,
        // so an unchanged set only changes when its oldest record ages out.
        let cutoff = now.addingTimeInterval(-RecapLedger.retention)
        if records != ledger.results || ledger.results.values.contains(where: { $0.completedAt <= cutoff }) {
            ledger.retainResults(records, now: now)
            records = ledger.results
        }
        return records.compactMap { $0.value.conflict || $0.value.invalidated ? $0.key : nil }
    }

    func isCompletedProgress(_ event: HookEvent, sourceID: String?) -> Bool {
        event.agent == .codex && event.turnID != nil
            && [.userPromptSubmit, .preToolUse, .postToolUse, .notification].contains(event.kind)
            && records.values.contains {
                $0.sourceID == sourceID && $0.sessionID == event.sessionID
                    && $0.agent == event.agent && $0.turnID == event.turnID
                    && event.timestamp <= $0.completedAt
            }
    }

    func isRejected(sessionID: String, completionID: String, sourceID: String?, now: Date = Date()) -> Bool {
        guard let sourceID,
              let record = records[RecapEntry.completedID(sourceID: sourceID, sessionID: sessionID, completionID: completionID)] else { return false }
        return !record.readable(now: now)
    }

    func isCurrent(session: AgentSession?, completionID: String, sourceID: String?) -> Bool {
        guard let session else { return false }
        if let sourceID,
           let record = records[RecapEntry.completedID(sourceID: sourceID, sessionID: session.id, completionID: completionID)],
           let run = runs[session.id],
           run.agent != record.agent || run.turnID != record.turnID || run.startedAt > record.completedAt { return false }
        return session.status == .done && !session.isStuck && session.probeRetired != true
            && session.completionID == completionID
    }

    enum ReadEvidence: Sendable {
        case text(String), unavailable, conflict, invalidated
    }

    struct ReadRequest: Sendable {
        fileprivate let record: Record

        func speechEvidenceIsSettled() -> Bool {
            if record.agent == .cursor, let offset = record.transcriptOffset {
                guard let path = record.transcriptPath, let text = record.text else { return false }
                return CursorCompletionReader.read(path: path, offset: offset) == text
            }
            guard record.agent == .claudeCode else { return true }
            guard let path = record.transcriptPath, let text = record.text else { return false }
            return ClaudeCompletionReader.hooksSettled(path: path, sessionID: record.sessionID,
                completedAt: record.completedAt, expectedText: text)
        }

        func readEvidence() -> ReadEvidence {
            guard let path = record.transcriptPath else { return .unavailable }
            if record.agent == .codex, let turn = record.turnID {
                switch CodexCompletionReader.read(path: path, sessionID: record.sessionID, turnID: turn) {
                case .success(let result): return .text(result.text)
                case .failure(let failure):
                    ContentPresentationService.diagnose(stage: "codexEvidence", reason: failure.rawValue)
                    if failure == .conflict { return .conflict }
                    if failure == .aborted { return .invalidated }
                    return .unavailable
                }
            }
            if record.agent == .claudeCode, let startedAt = record.startedAt {
                guard FileManager.default.isReadableFile(atPath: path) else {
                    ContentPresentationService.diagnose(stage: "claudeEvidence", reason: "sourceUnreadable")
                    return .unavailable
                }
                if let text = ClaudeCompletionReader.read(path: path, sessionID: record.sessionID,
                    startedAt: startedAt, completedAt: record.completedAt, expectedText: nil) { return .text(text) }
                ContentPresentationService.diagnose(stage: "claudeEvidence", reason: "intervalUnverified")
                return .unavailable
            }
            if record.agent == .cursor, let offset = record.transcriptOffset {
                return CursorCompletionReader.read(path: path, offset: offset).map(ReadEvidence.text) ?? .unavailable
            }
            ContentPresentationService.diagnose(stage: "evidence", reason: "unsupportedSourceOrMissingBoundary")
            return .unavailable
        }
    }

    func resultExcerpt(key: String) -> String? {
        guard let text = records[key]?.text, !text.isEmpty else { return nil }
        return String(text.prefix(240))
    }

    func speechRead(key: String, cursorFollowupHandedAt: Date?) -> ReadRequest? {
        guard let record = records[key] else { return nil }
        if record.agent == .cursor, let handedAt = cursorFollowupHandedAt,
           handedAt >= record.completedAt { return nil }
        return ReadRequest(record: record)
    }

    enum ReadPlan {
        case ready(FrozenCompletionResult), read(ReadRequest), unavailable
    }

    func retainedResult(key: String, now: Date) -> FrozenCompletionResult? {
        records[key]?.frozen(now: now)
    }

    func readPlan(key: String, sourceID: String?, now: Date) -> ReadPlan {
        guard let record = records[key], record.sourceID == sourceID, record.readable(now: now) else { return .unavailable }
        if let frozen = retainedResult(key: key, now: now) { return .ready(frozen) }
        guard record.transcriptPath != nil else {
            ContentPresentationService.diagnose(stage: "evidence", reason: "sourceLocatorUnavailable")
            return .unavailable
        }
        return .read(ReadRequest(record: record))
    }

    mutating func merge(_ evidence: ReadEvidence, for request: ReadRequest, sourceID: String?, now: Date) -> Bool {
        let record = request.record
        guard sourceID == record.sourceID, let current = records[record.id],
              current.turnID == record.turnID, current.startedAt == record.startedAt,
              current.completedAt == record.completedAt, current.readable(now: now) else { return false }
        switch evidence {
        case .conflict: records[record.id]?.conflict = true
        case .invalidated: records[record.id]?.invalidated = true
        case .text(let text): accept(text, id: record.id, now: now)
        case .unavailable: break
        }
        return true
    }

    enum BodyRead {
        case refused(CompletionBody), read(key: String)
    }

    func bodyRead(sessionID: String, completionID: String, session: AgentSession?, sourceID: String?) -> BodyRead {
        let reason: String
        if !isCurrent(session: session, completionID: completionID, sourceID: sourceID) {
            reason = "This completion is no longer current."
        } else if let sourceID {
            let key = RecapEntry.completedID(sourceID: sourceID, sessionID: sessionID, completionID: completionID)
            if records[key] != nil { return .read(key: key) }
            reason = "Legacy or unobserved completion: exact turn mapping is unknown."
        } else {
            reason = "Legacy or unobserved completion: exact turn mapping is unknown."
        }
        return .refused(CompletionBody(sourceID: sourceID, sessionID: sessionID, completionID: completionID, unavailableReason: reason))
    }

    func body(sessionID: String, completionID: String, session: AgentSession?, sourceID: String?,
              result: FrozenCompletionResult?, now: Date) -> CompletionBody {
        func unavailable(_ reason: String) -> CompletionBody {
            CompletionBody(sourceID: sourceID, sessionID: sessionID, completionID: completionID, unavailableReason: reason)
        }
        guard isCurrent(session: session, completionID: completionID, sourceID: sourceID) else {
            return unavailable("This completion is no longer current.")
        }
        if let result {
            return CompletionBody(sourceID: result.sourceID, sessionID: sessionID, completionID: completionID, text: result.finalText)
        }
        let record = sourceID.flatMap { records[RecapEntry.completedID(sourceID: $0, sessionID: sessionID, completionID: completionID)] }
        let reason = record?.conflict == true ? "Conflicting final result evidence; ordinary reading is refused."
            : record?.invalidated == true ? "This turn was aborted or invalidated."
            : record?.readable(now: now) != true ? "The retained result has expired."
            : "The final result could not be verified for this exact turn."
        return unavailable(reason)
    }

    enum NotificationState: Equatable {
        case finished(CompletionResultAvailability)
        case waiting(deadline: Date, needsRead: Bool)
    }

    func notificationState(sessionID: String, completionID: String, sourceID: String?, now: Date = Date()) -> NotificationState {
        guard !isRejected(sessionID: sessionID, completionID: completionID, sourceID: sourceID, now: now),
              let candidate = candidates[sessionID], candidate.completionID == completionID else { return .finished(.resultUnavailable) }
        if let outcome = candidate.outcome { return .finished(outcome) }
        return .waiting(deadline: candidate.completedAt.addingTimeInterval(2), needsRead: candidate.transcriptPath != nil)
    }

    func snapshotText(for session: AgentSession, sourceID: String?) -> String? {
        guard session.status == .done, !session.isStuck,
              !isRejected(sessionID: session.id, completionID: session.completionID ?? "", sourceID: sourceID),
              let candidate = candidates[session.id], candidate.completionID == session.completionID,
              case .ready(let result) = candidate.outcome, result.sourceID == sourceID else { return nil }
        return RowPresentation.firstSentence(result.finalText)
    }

    func recapResults(for sessions: [AgentSession], sourceID: String?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            guard let sourceID, !isRejected(sessionID: session.id, completionID: session.completionID ?? "", sourceID: sourceID),
                  let candidate = candidates[session.id], candidate.completionID == session.completionID else { return nil }
            let result: FrozenCompletionResult
            if let retained = candidate.readingResult { result = retained }
            else if case .ready(let captured) = candidate.outcome { result = captured }
            else { return nil }
            guard result.sourceID == sourceID else { return nil }
            return (RecapEntry.completedID(sourceID: sourceID, sessionID: session.id, completionID: result.completionID), result.finalText)
        })
    }

    func recapRecovery(in ledger: RecapLedger, now: Date) -> [(id: String, sessionID: String, completionID: String)] {
        ledger.entries.values.compactMap { entry in
            guard entry.resultText == nil, let completionID = entry.completionID,
                  records[entry.id]?.readable(now: now) == true else { return nil }
            return (entry.id, entry.sessionID, completionID)
        }
    }

    mutating func accept(_ text: String, id: String, now: Date) {
        guard var record = records[id], record.readable(now: now),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let first = record.text, first != text { record.conflict = true }
        else if text.count <= 12_000 { record.text = text }
        records[id] = record
        if var candidate = candidates[record.sessionID], candidate.completionID == record.completionID {
            if record.conflict {
                candidate.readingResult = nil
                candidate.outcome = .resultUnavailable
            } else {
                candidate.readingResult = record.frozen(now: now)
                if candidate.outcome == nil {
                    candidate.outcome = Self.freeze(text, candidate: candidate, sourceID: record.sourceID,
                        sessionID: record.sessionID, now: now)
                }
            }
            candidates[record.sessionID] = candidate
        }
    }

    mutating func observe(_ event: HookEvent, session: AgentSession?, sourceID: String?, now: Date,
                          authoritative: Bool = true, createdCompletion: Bool = false) {
        let id = event.sessionID
        let nativeResultEvidence = !(event.agent == .codex && event.observationSource == .hook)
        if event.agent == .codex, let sourceID, let turn = event.turnID,
           [.userPromptSubmit, .preToolUse, .postToolUse, .notification].contains(event.kind) {
            for key in records.keys where records[key]?.sourceID == sourceID
                && records[key]?.sessionID == id && records[key]?.agent == .codex
                && records[key]?.turnID == turn && records[key]?.text == nil {
                guard let record = records[key], event.timestamp > record.completedAt else { continue }
                records[key]?.invalidated = true
                if candidates[id]?.completionID == record.completionID { candidates[id] = nil }
            }
        }
        // Known older turns may enrich only their own existing record, even
        // after a new run replaced the current candidate.
        if event.kind == .stop, let sourceID {
            let matching = records.values.filter {
                $0.sourceID == sourceID && $0.sessionID == id && $0.agent == event.agent
                && ((event.turnID != nil && $0.turnID == event.turnID)
                    || (event.agent == .claudeCode && $0.turnID == nil && $0.completedAt == event.timestamp))
            }.map(\.id)
            for key in matching {
                if records[key]?.startedAt == nil, let boundary = event.turnStartedAt, boundary <= event.timestamp {
                    records[key]?.startedAt = boundary
                }
                if event.completionSucceeded == false || event.userStopped || event.probeRetirement {
                    records[key]?.invalidated = true
                    if candidates[id]?.completionID == records[key]?.completionID { candidates[id] = nil }
                    if runs[id]?.turnID == records[key]?.turnID,
                       runs[id]?.startedAt == records[key]?.startedAt, runs[id]?.agent == records[key]?.agent { runs[id] = nil }
                } else if nativeResultEvidence, event.completionSucceeded == true, let text = event.completionText {
                    if records[key]?.transcriptPath == nil { records[key]?.transcriptPath = event.transcriptPath }
                    accept(text, id: key, now: now)
                } else if records[key]?.transcriptPath == nil { records[key]?.transcriptPath = event.transcriptPath }
            }
            if !matching.isEmpty && !createdCompletion { return }
        }
        // App-server can first discover an already-ended native turn. Its
        // successful ending proves this mapping without inventing a prompt
        // boundary. Only a fresh Hook can also start notification capture.
        if authoritative, createdCompletion, event.kind == .stop, event.agent == .codex,
           event.completionSucceeded == true, !event.userStopped, !event.probeRetirement,
           runs[id] == nil, let turn = event.turnID, !turn.isEmpty,
           let sourceID, let session, session.status == .done, !session.isStuck,
           let completionID = session.completionID {
            let key = RecapEntry.completedID(sourceID: sourceID, sessionID: id, completionID: completionID)
            if records[key] == nil {
                if event.observationSource == .hook {
                    candidates[id] = Candidate(completionID: completionID, turnID: turn,
                        title: session.displayTitle, completedAt: event.timestamp, transcriptPath: event.transcriptPath)
                }
                records[key] = Record(sourceID: sourceID, sessionID: id, completionID: completionID,
                    agent: event.agent, turnID: turn, title: session.displayTitle,
                    startedAt: event.turnStartedAt, completedAt: event.timestamp, transcriptPath: event.transcriptPath)
                if nativeResultEvidence, let text = event.completionText { accept(text, id: key, now: now) }
            }
            return
        }
        if let boundary = event.turnStartedAt, let turn = event.turnID {
            if let old = runs[id], boundary < old.startedAt {
                // App-server discovery can start an anonymous run after the
                // native turn actually began. A native event spanning that
                // observation refines it; an older ending or identified turn
                // cannot replace a newer run.
                guard event.agent == .codex, old.agent == .codex, old.turnID == nil,
                      nativeResultEvidence, event.timestamp >= old.startedAt else { return }
            }
            if runs[id]?.turnID != turn || runs[id] == nil {
                runs[id] = Run(agent: event.agent, startedAt: boundary, turnID: turn, transcriptPath: event.transcriptPath)
                candidates[id] = nil
            } else if runs[id]?.transcriptPath == nil { runs[id]?.transcriptPath = event.transcriptPath }
        }
        if event.kind == .userPromptSubmit {
            if let old = runs[id], event.timestamp < old.startedAt { return }
            if let turn = event.turnID, runs[id]?.turnID == turn {
                if runs[id]?.transcriptPath == nil { runs[id]?.transcriptPath = event.transcriptPath }
                return
            }
            if event.agent == .claudeCode || runs[id] == nil || event.turnID != nil || candidates[id] != nil {
                runs[id] = Run(agent: event.agent, startedAt: event.turnStartedAt ?? event.timestamp, turnID: event.turnID,
                    transcriptPath: event.transcriptPath)
                if event.agent == .cursor, event.observationSource != .transcript, event.observationSource != .acp,
                   let path = event.transcriptPath {
                    runs[id]?.transcriptOffset = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
                }
            }
            candidates[id] = nil
            return
        }
        if event.kind == .sessionEnd || (event.kind == .sessionStart && event.agent == .claudeCode) {
            runs[id] = nil; candidates[id] = nil
            return
        }
        if authoritative, event.kind == .stop, event.turnID == nil,
           let currentRun = runs[id], currentRun.agent == event.agent, event.timestamp >= currentRun.startedAt,
           event.completionSucceeded == false || event.probeRetirement || event.userStopped {
            if let sourceID, let candidate = candidates[id] {
                let key = RecapEntry.completedID(sourceID: sourceID, sessionID: id, completionID: candidate.completionID)
                records[key]?.invalidated = true
            }
            runs[id] = nil; candidates[id] = nil
            return
        }
        guard event.kind == .stop, let run = runs[id], run.agent == event.agent, event.timestamp >= run.startedAt else { return }
        // A Codex Hook Stop reports success without a turn ID. It can end the
        // observed run, but only native terminal evidence can supply its result.
        let progressOnly = event.agent == .codex && event.completionSucceeded != false
            && (event.turnID == nil || (event.completionSucceeded == nil && event.turnID == run.turnID))
        if let turn = run.turnID, event.turnID != turn, !progressOnly { return }
        if event.completionSucceeded == false || event.probeRetirement || event.userStopped {
            runs[id] = nil; candidates[id] = nil
            return
        }
        guard authoritative, let sourceID, let session, session.status == .done,
              !session.isStuck, session.probeRetired != true, let completionID = session.completionID else { return }
        if event.agent == .codex {
            guard let turn = run.turnID, !turn.isEmpty, event.turnID == turn || progressOnly else { return }
        }
        guard event.completionSucceeded == true || progressOnly else { return }
        let key = RecapEntry.completedID(sourceID: sourceID, sessionID: id, completionID: completionID)
        // Only the reducer creating this opaque completion can introduce its mapping.
        // A restored legacy UUID must remain unknown even if a later event has a boundary.
        guard records[key] != nil || createdCompletion else { return }
        // An existing mapping cannot be reassigned by another ending.
        if let existing = records[key], existing.turnID != run.turnID { return }
        // A released Claude Stop settles later than it happened; its
        // transcript proof is stamped at the original stop.
        let completedAt = event.pausedAt ?? event.timestamp
        var candidate = candidates[id] ?? Candidate(completionID: completionID, turnID: run.turnID,
            title: session.displayTitle, completedAt: completedAt,
            transcriptPath: event.transcriptPath ?? run.transcriptPath)
        if candidate.completionID != completionID {
            candidate = Candidate(completionID: completionID, turnID: run.turnID, title: session.displayTitle,
                completedAt: completedAt, transcriptPath: event.transcriptPath ?? run.transcriptPath)
        }
        candidates[id] = candidate
        if records[key] == nil {
            records[key] = Record(sourceID: sourceID, sessionID: id, completionID: completionID,
                agent: event.agent, turnID: run.turnID, title: candidate.title, startedAt: run.startedAt,
                completedAt: candidate.completedAt, transcriptPath: candidate.transcriptPath)
            records[key]?.transcriptOffset = run.transcriptOffset
        }
        if nativeResultEvidence, !progressOnly, event.completionSucceeded == true, let text = event.completionText {
            // Claude Stop.last_assistant_message is the successful final reply;
            // its transcript can lag. StopFailure never reaches this branch.
            accept(text, id: key, now: now)
        }
    }

    private static func freeze(_ text: String, candidate: Candidate, sourceID: String,
                       sessionID: String, now: Date) -> CompletionResultAvailability {
        guard now <= candidate.completedAt.addingTimeInterval(2) else { return .expired }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .resultUnavailable }
        guard text.count <= 12_000 else { return .resultTooLong }
        return .ready(FrozenCompletionResult(sourceID: sourceID, sessionID: sessionID,
                     completionID: candidate.completionID, turnID: candidate.turnID,
                     title: candidate.title, finalText: text,
                     completedAt: candidate.completedAt, observedAt: now))
    }
}

/// Reads only a bounded tail; partial records and ambiguous/newer turns fail closed.
/// Fallback only when a successful Stop omitted its final text. A missing
/// observed prompt boundary is unavailable; later rounds are not borrowed.
enum ClaudeCompletionReader {
    static func read(path: String, sessionID: String, startedAt: Date,
                     completedAt: Date, expectedText: String?) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        let start = size > 1_048_576 ? size - 1_048_576 : 0
        guard (try? file.seek(toOffset: start)) != nil,
              let data = try? file.readToEnd() else { return nil }
        return parse(data, dropsFirstLine: start > 0, sessionID: sessionID,
                     startedAt: startedAt, completedAt: completedAt, expectedText: expectedText)
    }

    static func parse(_ data: Data, dropsFirstLine: Bool = false, sessionID: String,
                      startedAt: Date, completedAt: Date, expectedText: String?) -> String? {
        // The trailing newline proves the final JSONL record was fully flushed.
        guard data.last == 10 else { return nil }
        var lines = data.split(separator: 10)
        if dropsFirstLine, !lines.isEmpty { lines.removeFirst() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var final: String?
        for line in lines {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
            guard row["sessionId"] as? String == sessionID,
                  row["isSidechain"] as? Bool != true,
                  let type = row["type"] as? String, type == "user" || type == "assistant",
                  let stamp = row["timestamp"] as? String,
                  let date = formatter.date(from: stamp) ?? plain.date(from: stamp) else { continue }
            guard date >= startedAt else { continue }
            // This stored round owns only its observed interval. Later rounds
            // cannot replace or invalidate its own terminal record.
            guard date <= completedAt else { continue }
            final = nil
            guard type == "assistant", let message = row["message"] as? [String: Any],
                  message["stop_reason"] as? String == "end_turn",
                  let content = message["content"] as? [[String: Any]],
                  !content.contains(where: { $0["type"] as? String == "tool_use" }) else { continue }
            let text = content.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { final = text }
        }
        guard let final else { return nil }
        if let expectedText, expectedText != final { return nil }
        return final
    }
}

/// Cursor hook results are read only from bytes appended after this run began.
/// An earlier turn, a subsequent prompt, or an unfinished response is not a result.
enum CursorCompletionReader {
    static func read(path: String, offset: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= offset, size - offset <= 2 * 1_024 * 1_024,
              (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), data.last == 10 else { return nil }
        var text: String?
        var ended = false
        var sawPrompt = false
        for raw in data.split(separator: 10) {
            guard (try? JSONSerialization.jsonObject(with: Data(raw))) != nil else { return nil }
            for line in CursorTranscripts.parse(line: String(decoding: raw, as: UTF8.self), fullContent: true) {
                guard !ended else { return nil }
                switch line {
                case .prompt:
                    guard !sawPrompt, text == nil else { return nil }
                    sawPrompt = true
                case .assistantText(let value): text = value
                case .toolUse: text = nil
                case .turnEnded(let status, _):
                    guard status == "success" else { return nil }
                    ended = true
                }
            }
        }
        guard ended, let text, !text.isEmpty, text.count <= 12_000 else { return nil }
        return text
    }
}

extension ClaudeCompletionReader {
    static func hooksSettled(path: String, sessionID: String, completedAt: Date, expectedText: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        let offset = size > 1_048_576 ? size - 1_048_576 : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), data.last == 10 else { return false }
        var lines = data.split(separator: 10)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        var matches = false
        var settled = false
        for line in lines {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return false }
            guard (row["sessionId"] as? String ?? row["session_id"] as? String) == sessionID,
                  row["isSidechain"] as? Bool != true else { continue }
            if row["type"] as? String == "user" { matches = false; settled = false }
            if row["type"] as? String == "assistant" {
                settled = false
                let message = row["message"] as? [String: Any]
                let content = message?["content"] as? [[String: Any]] ?? []
                let text = content.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                matches = message?["stop_reason"] as? String == "end_turn" && text == expectedText
                    && !content.contains { $0["type"] as? String == "tool_use" }
            }
            if row["type"] as? String == "system", row["subtype"] as? String == "stop_hook_summary" {
                let stamp = row["timestamp"] as? String ?? ""
                let date = formatter.date(from: stamp) ?? seconds.date(from: stamp)
                settled = matches && (date.map { $0 >= completedAt.addingTimeInterval(-1) } ?? false)
                    && row["preventedContinuation"] as? Bool == false
                    && (row["stopReason"] as? String ?? "").isEmpty
                    && (row["hookAdditionalContext"] as? [Any] ?? []).isEmpty
                    && (row["hookErrors"] as? [Any] ?? []).isEmpty
            }
        }
        return settled
    }
}
