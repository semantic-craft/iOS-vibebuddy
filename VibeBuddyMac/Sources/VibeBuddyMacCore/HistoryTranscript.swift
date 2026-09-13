import Foundation
import CoreFoundation

/// Native identity plus an optional, one-based readable message position.
public struct HistorySessionReference: Sendable {
    public let agent: SessionHistoryAgent
    public let nativeID: String
    public let seq: Int?
    public var key: String { agent.keyName + ":" + nativeID }
    public init(_ value: String) throws {
        let prefix = "vibebuddy://session/"
        let isRef = value.hasPrefix(prefix)
        let parts = (isRef ? String(value.dropFirst(prefix.count)) : value).split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count <= (isRef ? 2 : 1), let raw = parts.first,
              let colon = raw.firstIndex(of: ":") else { throw HistoryToolError.executionFailed("Invalid session key or reference.") }
        switch raw[..<colon] {
        case "claude-code": agent = .claude
        case "codex": agent = .codex
        case "cursor": agent = .cursor
        default: throw HistoryToolError.executionFailed("Unknown session agent.")
        }
        nativeID = String(raw[raw.index(after: colon)...])
        guard !nativeID.isEmpty, nativeID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else {
            throw HistoryToolError.executionFailed("Invalid native session ID.")
        }
        if parts.count == 2 {
            guard let number = Int(parts[1]), number > 0 else { throw HistoryToolError.executionFailed("Invalid reference sequence.") }
            seq = number
        } else { seq = nil }
    }
    public func ref(seq: Int) -> String { "vibebuddy://session/\(key)#\(seq)" }
}

public struct HistoryTranscript: Sendable {
    public let session: SessionHistorySession
    public let provenance: String
    /// One-based references index this fixed projection. Meta is absent; standalone
    /// Thinking retains a position even when default output hides it. Expansion
    /// flags never renumber a later dialogue or tool row.
    public let rows: [HistoryMessageRow]
    private let sequences: [String: Int]
    public init(session: SessionHistorySession, provenance: String) {
        self.session = session; self.provenance = provenance
        rows = SessionHistoryPresentation.rows(session.messages, includingThinking: true)
        var mapping: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            for id in row.messageIDs { mapping[id] = index + 1 }
        }
        sequences = mapping
    }
    public func seq(messageID: String) -> Int? { sequences[messageID] }
}

extension HistoryTools {
    public static func getSession(arguments: [String: Any], repository: SessionHistoryRepository) async throws -> String {
        guard Set(arguments.keys).isSubset(of: ["key", "from_seq", "max_messages", "tools", "thinking"]), let key = arguments["key"] as? String else {
            throw HistoryToolError.invalidArguments("get_session requires key and only its documented arguments.")
        }
        let reference = try HistorySessionReference(key)
        func integer(_ name: String, fallback: Int, maximum: Int) throws -> Int {
            guard let value = arguments[name] else { return fallback }
            let result: Int?
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
               number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= 1, number.doubleValue <= Double(maximum) { result = number.intValue }
            else if let text = value as? String { result = Int(text) }
            else { result = nil }
            guard let result, (1...maximum).contains(result) else { throw HistoryToolError.invalidArguments("Invalid argument: \(name)") }
            return result
        }
        func flag(_ name: String) throws -> Bool {
            guard let value = arguments[name] else { return false }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw HistoryToolError.invalidArguments("Invalid argument: \(name)") }
            return number.boolValue
        }
        let from = try integer("from_seq", fallback: reference.seq ?? 1, maximum: Int.max)
        let limit = try integer("max_messages", fallback: 30, maximum: 200)
        let tools = try flag("tools"), thinking = try flag("thinking")
        let transcript = try await repository.readTranscript(key: reference.key)
        let session = transcript.session
        let rows = transcript.rows
        let page = rows.enumerated().filter { $0.offset >= from - 1 && (thinking || !$0.element.text.isEmpty || !$0.element.tools.isEmpty) }.prefix(limit)
        var lines = ["Source revision: \(session.sourceRevision ?? "unknown") (\(transcript.provenance))", "", "# \(session.title)", "Key: \(reference.key)"]
        lines += session.warnings.map { "> " + $0 }
        if !session.isAvailable { lines.append("> Source unavailable; reading retained cached history.") }
        for (index, row) in page {
            lines += ["", "## [seq \(index + 1)] \(row.kind == .compactSummary ? "Context compaction" : row.role.rawValue.capitalized)"]
            if !row.text.isEmpty { lines.append(row.text) }
            if thinking, !row.thinking.isEmpty { lines += ["", "Thinking:", row.thinking] }
            for tool in row.tools {
                lines.append("- Tool: \(tool.name)\(tool.isError ? " (error)" : "") — \(tool.preview)")
                if tools {
                    if !tool.input.isEmpty { lines += ["", "Input:", tool.input] }
                    if let output = tool.output { lines += ["", "Result:", output] }
                }
            }
        }
        if let last = page.last?.offset, rows.enumerated().contains(where: { $0.offset > last && (thinking || !$0.element.text.isEmpty || !$0.element.tools.isEmpty) }) {
            lines += ["", "Continue: from_seq=\(last + 2) (\(reference.ref(seq: last + 2)))"]
        } else { lines += ["", "End of readable transcript."] }
        return lines.joined(separator: "\n")
    }
}
