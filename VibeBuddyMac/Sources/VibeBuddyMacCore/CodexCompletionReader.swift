import Foundation

/// Reads only an explicitly named successful Codex turn. This does not emit
/// progress events and is safe to use for an already persisted completion key.
public enum CodexCompletionReader {
    public struct CompletedTurn: Equatable, Sendable {
        public let text: String
        public let startedAt: Date
        public let completedAt: Date
    }

    public enum Failure: String, Error, Sendable {
        case unreadable, readLimitExceeded, malformedRecord, sessionMismatch
        case missingBoundary, notCompleted, aborted, emptyBody, bodyTooLarge, conflict
    }

    /// Limit total I/O as well as line allocation; never read an arbitrary
    /// multi-gigabyte transcript into memory on a presentation request.
    public static func read(
        path: String, sessionID: String, turnID: String,
        maxBytes: Int = 64 * 1_024 * 1_024
    ) -> Result<CompletedTurn, Failure> {
        guard !sessionID.isEmpty, !turnID.isEmpty else { return .failure(.missingBoundary) }
        guard maxBytes > 0, let handle = FileHandle(forReadingAtPath: path) else {
            return .failure(.unreadable)
        }
        defer { try? handle.close() }
        var pending = Data()
        var bytes = 0
        var sawSession = false
        var startedAt: Date?
        var result: CompletedTurn?
        var rejected: Failure?
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let secondsFormatter = ISO8601DateFormatter()
        func timestamp(_ root: [String: Any]) -> Date? {
            guard let value = root["timestamp"] as? String else { return nil }
            return formatter.date(from: value) ?? secondsFormatter.date(from: value)
        }
        do {
            while let chunk = try handle.read(upToCount: min(64 * 1_024, maxBytes - bytes + 1)), !chunk.isEmpty {
                bytes += chunk.count
                guard bytes <= maxBytes else { return .failure(.readLimitExceeded) }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0a) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let type = root["type"] as? String,
                          let payload = root["payload"] as? [String: Any] else {
                        return .failure(.malformedRecord)
                    }
                    if type == "session_meta" {
                        guard payload["id"] as? String == sessionID else { return .failure(.sessionMismatch) }
                        sawSession = true
                        continue
                    }
                    guard sawSession else { return .failure(.sessionMismatch) }
                    guard type == "event_msg", let event = payload["type"] as? String else { continue }
                    // An anonymous abort while the target is pending cannot
                    // prove success, even if a later duplicate complete exists.
                    if event == "turn_aborted", payload["turn_id"] == nil, startedAt != nil, result == nil {
                        rejected = .aborted
                    }
                    guard payload["turn_id"] as? String == turnID else { continue }
                    switch event {
                    case "task_started":
                        guard let date = timestamp(root) else { return .failure(.missingBoundary) }
                        if let startedAt, startedAt != date { rejected = .conflict }
                        else { startedAt = date }
                    case "turn_aborted": rejected = .aborted
                    case "task_complete":
                        guard let start = startedAt, let end = timestamp(root), end >= start else {
                            rejected = rejected ?? .missingBoundary
                            continue
                        }
                        guard let raw = payload["last_agent_message"] as? String,
                              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            rejected = rejected ?? .emptyBody
                            continue
                        }
                        guard raw.count <= 12_000 else { rejected = rejected ?? .bodyTooLarge; continue }
                        let candidate = CompletedTurn(text: raw, startedAt: start, completedAt: end)
                        if let result, result.text != candidate.text { rejected = .conflict }
                        else if result == nil { result = candidate }
                    default: break
                    }
                }
                guard pending.count <= 2 * 1_024 * 1_024 else { return .failure(.readLimitExceeded) }
            }
        } catch { return .failure(.unreadable) }
        // The final unterminated line is an in-progress append, never evidence.
        if let rejected { return .failure(rejected) }
        guard sawSession else { return .failure(.sessionMismatch) }
        guard startedAt != nil else { return .failure(.missingBoundary) }
        guard let result else { return .failure(.notCompleted) }
        return .success(result)
    }
}
