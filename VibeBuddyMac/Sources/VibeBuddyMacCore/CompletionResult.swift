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
    struct Run {
        let agent: AgentKind
        let startedAt: Date
        let turnID: String?
        var transcriptPath: String? = nil
    }
    struct Candidate: Sendable {
        let completionID: String
        let turnID: String?
        let title: String
        let completedAt: Date
        let startedAt: Date
        let transcriptPath: String?
        var expectedText: String?
        var outcome: CompletionResultAvailability?
        var readingResult: FrozenCompletionResult?
    }
    var runs: [String: Run] = [:]
    var candidates: [String: Candidate] = [:]
    var records: [String: Record] = [:]

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
                } else if event.completionSucceeded == true, let text = event.completionText {
                    if records[key]?.transcriptPath == nil { records[key]?.transcriptPath = event.transcriptPath }
                    accept(text, id: key, now: now)
                } else if records[key]?.transcriptPath == nil { records[key]?.transcriptPath = event.transcriptPath }
            }
            if !matching.isEmpty { return }
        }
        // App-server can first discover an already-ended native turn. Its
        // successful ending proves this mapping, but does not invent a prompt
        // boundary or revive notification capture. A rollout may enrich it later.
        if authoritative, createdCompletion, event.kind == .stop, event.agent == .codex,
           event.completionSucceeded == true, !event.userStopped, !event.probeRetirement,
           runs[id] == nil, let turn = event.turnID, !turn.isEmpty,
           let sourceID, let session, session.status == .done, !session.isStuck,
           let completionID = session.completionID {
            let key = RecapEntry.completedID(sourceID: sourceID, sessionID: id, completionID: completionID)
            if records[key] == nil {
                records[key] = Record(sourceID: sourceID, sessionID: id, completionID: completionID,
                    agent: event.agent, turnID: turn, title: session.displayTitle,
                    startedAt: event.turnStartedAt, completedAt: event.timestamp, transcriptPath: event.transcriptPath)
                if let text = event.completionText { accept(text, id: key, now: now) }
            }
            return
        }
        if let boundary = event.turnStartedAt, let turn = event.turnID {
            if let old = runs[id], boundary < old.startedAt { return }
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
        let progressOnly = event.agent == .codex && event.completionSucceeded == nil
            && (event.turnID == nil || event.turnID == run.turnID)
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
        var candidate = candidates[id] ?? Candidate(completionID: completionID, turnID: run.turnID,
            title: session.displayTitle, completedAt: event.timestamp, startedAt: run.startedAt,
            transcriptPath: event.transcriptPath ?? run.transcriptPath)
        if candidate.completionID != completionID {
            candidate = Candidate(completionID: completionID, turnID: run.turnID, title: session.displayTitle,
                completedAt: event.timestamp, startedAt: run.startedAt, transcriptPath: event.transcriptPath ?? run.transcriptPath)
        }
        candidates[id] = candidate
        if records[key] == nil {
            records[key] = Record(sourceID: sourceID, sessionID: id, completionID: completionID,
                agent: event.agent, turnID: run.turnID, title: candidate.title, startedAt: run.startedAt,
                completedAt: candidate.completedAt, transcriptPath: candidate.transcriptPath)
        }
        if event.completionSucceeded == true, let text = event.completionText {
            // Claude Stop.last_assistant_message is the successful final reply;
            // its transcript can lag. StopFailure never reaches this branch.
            accept(text, id: key, now: now)
        }
    }

    static func freeze(_ text: String, candidate: Candidate, sourceID: String,
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
