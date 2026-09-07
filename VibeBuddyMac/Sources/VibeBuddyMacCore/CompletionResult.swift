import Foundation
import VibeBuddyKit

/// Memory-only evidence. Never serialize this into snapshots or the lifecycle journal.
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
    struct Run {
        let startedAt: Date
        let turnID: String?
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
    }
    var runs: [String: Run] = [:]
    var candidates: [String: Candidate] = [:]

    mutating func observe(_ event: HookEvent, session: AgentSession?, sourceID: String?, now: Date) {
        let id = event.sessionID
        if (event.kind == .stop && event.completionSucceeded == false)
            || event.kind == .sessionEnd || event.probeRetirement
            || (event.kind == .sessionStart && event.agent == .claudeCode) {
            runs[id] = nil
            candidates[id] = nil
            return
        }
        if event.kind == .userPromptSubmit {
            // Repeated status corroboration without a turn ID does not replace
            // a known run. A genuine labelled new turn always invalidates it.
            if event.agent == .claudeCode || runs[id] == nil || event.turnID != nil || candidates[id] != nil {
                runs[id] = Run(startedAt: event.timestamp, turnID: event.turnID)
            }
            candidates[id] = nil
            return
        }
        guard let session, session.status == .done, !session.isStuck,
              session.probeRetired != true, let completionID = session.completionID else {
            candidates[id] = nil
            return
        }
        guard event.kind == .stop, let run = runs[id], event.timestamp >= run.startedAt else { return }
        let progressOnly = event.agent == .codex && event.completionSucceeded == nil && event.turnID == nil
        if let current = run.turnID, event.turnID != current, !progressOnly { return }
        if event.agent == .codex {
            guard let turn = run.turnID, !turn.isEmpty, event.turnID == turn || progressOnly else { return }
        }
        guard event.completionSucceeded == true
            || (event.agent == .codex && event.completionSucceeded == nil) else { return }
        if let candidate = candidates[id], candidate.completionID == completionID {
            // A labelled duplicate may supply missing final evidence within the
            // original deadline; it cannot replace a frozen result or ending.
            if candidate.outcome == nil, [AgentKind.codex, .grokBot].contains(event.agent), event.completionSucceeded == true,
               let turn = event.turnID, turn == candidate.turnID,
               let text = event.completionText, let sourceID {
                candidates[id]?.outcome = Self.freeze(text, candidate: candidate,
                    sourceID: sourceID, sessionID: id, now: now)
            }
            return
        }
        var candidate = Candidate(completionID: completionID, turnID: [AgentKind.codex, .grokBot].contains(event.agent) ? run.turnID : event.turnID,
                                  title: session.displayTitle, completedAt: event.timestamp,
                                  startedAt: run.startedAt,
                                  transcriptPath: event.agent == .claudeCode ? event.transcriptPath : nil,
                                  expectedText: event.agent == .claudeCode ? event.completionText : nil)
        if event.agent == .claudeCode, let text = event.completionText, text.count > 12_000 {
            candidate.outcome = .resultTooLong
            candidate.expectedText = nil
        }
        if [AgentKind.codex, .grokBot].contains(event.agent), event.completionSucceeded == true, let turn = event.turnID, !turn.isEmpty,
           let text = event.completionText, let sourceID {
            candidate.outcome = Self.freeze(text, candidate: candidate, sourceID: sourceID, sessionID: id, now: now)
        }
        candidates[id] = candidate
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
/// The Stop text is cross-checked when present, never used as a substitute for
/// a terminal assistant record. A missing observed prompt boundary is unavailable.
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
            // A later message means this file is no longer a proof of this ending.
            guard date <= completedAt else { return nil }
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
