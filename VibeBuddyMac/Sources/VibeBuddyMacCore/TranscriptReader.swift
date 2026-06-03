import Foundation

/// Derived metadata pulled from a session's JSONL transcript.
public struct TranscriptInfo: Equatable, Sendable {
    public var model: String?
    public var tokens: Int?
    public var summary: String?

    public init(model: String? = nil, tokens: Int? = nil, summary: String? = nil) {
        self.model = model
        self.tokens = tokens
        self.summary = summary
    }
}

/// Reads a coding agent's JSONL transcript to extract the latest assistant
/// model, current-turn token usage, and last prose reply. Scans backward from
/// the tail; a partial leading line (when only the tail was read) is skipped.
public enum TranscriptReader {

    /// Parse already-read transcript bytes (the tail). Pure, no I/O.
    public static func parse(tail data: Data, summaryLimit: Int = 220) -> TranscriptInfo {
        let text = String(decoding: data, as: UTF8.self)
        var info = TranscriptInfo()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            let message = (obj["message"] as? [String: Any]) ?? obj
            guard (message["role"] as? String) == "assistant" else { continue }

            if info.summary == nil {
                info.summary = Self.text(from: message["content"], limit: summaryLimit)
            }
            if info.tokens == nil, let usage = message["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                info.tokens = input + output
            }
            if info.model == nil, let model = message["model"] as? String, !model.isEmpty {
                info.model = model
            }
            if info.summary != nil, info.tokens != nil, info.model != nil { break }
        }
        return info
    }

    /// Read the last `maxBytes` of a transcript file and parse it. nil if unreadable.
    public static func read(path: String, maxBytes: Int = 131_072, summaryLimit: Int = 220) -> TranscriptInfo? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            return parse(tail: data, summaryLimit: summaryLimit)
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static func text(from content: Any?, limit: Int) -> String? {
        let raw: String?
        if let string = content as? String {
            raw = string
        } else if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            raw = texts.isEmpty ? nil : texts.joined(separator: " ")
        } else {
            raw = nil
        }

        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(limit))
    }
}
