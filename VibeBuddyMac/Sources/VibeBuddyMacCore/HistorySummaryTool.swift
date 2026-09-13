import Foundation

/// A saved reading aid, checked against source attributes at query time.
public struct HistorySummaryRead: Sendable {
    public let summary: SessionHistorySummary
    public let currentSourceRevision: String?
    public let isStale: Bool
}

extension HistoryTools {
    public static func getSummary(arguments: [String: Any], repository: SessionHistoryRepository) async throws -> String {
        guard Set(arguments.keys) == ["key"], let key = arguments["key"] as? String else {
            throw HistoryToolError.invalidArguments("get_summary requires only a string key.")
        }
        let reference = try HistorySessionReference(key)
        guard let result = try await repository.readSummary(key: reference.key) else {
            return "No saved summary for \(reference.key). Open this session in Mac App History and choose Generate summary."
        }
        let summary = result.summary
        var lines = ["stale: \(result.isStale); Coverage: \(summary.coverage)", "",
            "Key: \(reference.key)",
            "Style: \(summary.style.rawValue) (\(summary.style.title))",
            "Provider: \(summary.provider)", "Model: \(summary.model)",
            "Generated: \(ISO8601DateFormatter().string(from: summary.generatedAt))",
            "Summary source revision: \(summary.sourceRevision ?? "unknown")",
            "Current source revision: \(result.currentSourceRevision ?? "unknown")"]
        if result.currentSourceRevision == nil {
            lines.append("> Source unavailable; freshness cannot be verified. The saved summary is retained.")
        } else if summary.sourceRevision == nil {
            lines.append("> Saved source revision unknown; freshness cannot be verified.")
        } else if result.isStale {
            lines.append("> Source changed since this summary was saved. The saved summary is retained.")
        }
        lines += ["", summary.text]
        return lines.joined(separator: "\n")
    }
}
