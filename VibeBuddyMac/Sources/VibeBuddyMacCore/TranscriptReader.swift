import Foundation
import VibeBuddyKit

/// Derived metadata pulled from a session's JSONL transcript.
public struct TranscriptInfo: Equatable, Sendable {
    public var model: String?
    public var tokens: Int?           // turn cost: input + output
    public var contextTokens: Int?    // prompt sent: input + cache_read + cache_creation
    public var summary: String?
    public var pendingQuestion: PendingQuestion?

    public init(model: String? = nil, tokens: Int? = nil,
                contextTokens: Int? = nil, summary: String? = nil,
                pendingQuestion: PendingQuestion? = nil) {
        self.model = model
        self.tokens = tokens
        self.contextTokens = contextTokens
        self.summary = summary
        self.pendingQuestion = pendingQuestion
    }
}

/// One line of a session's recent output: a user prompt or an assistant turn
/// (its prose, or a compact "⚙ ToolName" when the turn was pure tool use).
public struct TranscriptEntry: Equatable, Sendable {
    public let role: String   // "user" | "assistant"
    public let text: String
    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

/// Reads a coding agent's JSONL transcript to extract the latest assistant
/// model, current-turn token usage, and last prose reply. Scans backward from
/// the tail; a partial leading line (when only the tail was read) is skipped.
public enum TranscriptReader {

    /// The session's most recent output as ordered entries (oldest→newest), for
    /// the detail pane: user prompts and assistant prose / tool activity. Noisy
    /// tool-result turns are dropped. Pure, no I/O — operates on already-read bytes.
    public static func recentEntries(tail data: Data, limit: Int = 12,
                                     perEntryLimit: Int = 600) -> [TranscriptEntry] {
        let text = String(decoding: data, as: UTF8.self)
        var entries: [TranscriptEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }      // unparseable (e.g. a tail cut mid-record) → skip
            let message = (obj["message"] as? [String: Any]) ?? obj
            guard let role = message["role"] as? String, role == "user" || role == "assistant"
            else { continue }
            guard let body = entryText(from: message["content"], limit: perEntryLimit), !body.isEmpty
            else { continue }       // empty (e.g. a tool_result-only user turn) → skip
            entries.append(TranscriptEntry(role: role, text: body))
        }
        return Array(entries.suffix(limit))
    }

    /// Read the last `maxBytes` of a transcript file and parse its recent entries.
    /// nil if unreadable (no transcript / missing file).
    public static func recentEntries(path: String, maxBytes: Int = 262_144,
                                     limit: Int = 12, perEntryLimit: Int = 600) -> [TranscriptEntry]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            return recentEntries(tail: data, limit: limit, perEntryLimit: perEntryLimit)
        } catch {
            return nil
        }
    }

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
            if info.pendingQuestion == nil {
                info.pendingQuestion = Self.pendingQuestion(from: message["content"])
            }
            if info.tokens == nil, let usage = message["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                info.tokens = input + output
                info.contextTokens = input + cacheRead + cacheCreate
            }
            if info.model == nil, let model = message["model"] as? String, !model.isEmpty {
                info.model = model
            }
            if info.summary != nil, info.tokens != nil, info.model != nil,
               info.pendingQuestion != nil { break }
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

    /// Render one message's content for the recent-output list: text blocks joined,
    /// plus a "⚙ ToolName" marker for tool_use blocks. tool_result blocks (noise)
    /// are ignored, so a pure tool-result turn collapses to nil.
    private static func entryText(from content: Any?, limit: Int) -> String? {
        if let string = content as? String { return collapse(string, limit: limit) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        var parts: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { parts.append(t) }
            case "tool_use":
                if let name = block["name"] as? String { parts.append("⚙ \(name)") }
            default:
                continue        // tool_result / thinking / images → skip
            }
        }
        return collapse(parts.joined(separator: " "), limit: limit)
    }

    /// Collapse runs of whitespace and truncate; nil when nothing is left.
    private static func collapse(_ raw: String, limit: Int) -> String? {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(limit))
    }

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

    private static func pendingQuestion(from content: Any?) -> PendingQuestion? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks.reversed() {
            guard (block["type"] as? String) == "tool_use",
                  let name = block["name"] as? String,
                  Self.isAskUserQuestion(name),
                  let input = block["input"] as? [String: Any]
            else { continue }
            return Self.pendingQuestion(fromInput: input, fallbackID: block["id"] as? String)
        }
        return nil
    }

    private static func isAskUserQuestion(_ name: String) -> Bool {
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: "")
        return normalized == "askuserquestion" || normalized == "askquestion"
    }

    private static func pendingQuestion(fromInput input: [String: Any], fallbackID: String?) -> PendingQuestion? {
        let questionObject: [String: Any]
        if let questions = input["questions"] as? [[String: Any]], let first = questions.first {
            questionObject = first
        } else {
            questionObject = input
        }
        let prompt = Self.firstString(questionObject, keys: ["question", "prompt", "message", "text"])
        guard let prompt, !prompt.isEmpty else { return nil }
        let id = Self.firstString(questionObject, keys: ["id", "name"]) ?? fallbackID ?? "question"
        let options = Self.options(from: questionObject["options"])
        return PendingQuestion(id: id, prompt: prompt, options: options)
    }

    private static func options(from raw: Any?) -> [QuestionOption] {
        if let strings = raw as? [String] {
            return strings.map { QuestionOption(id: $0, label: $0) }
        }
        guard let objects = raw as? [[String: Any]] else { return [] }
        return objects.compactMap { object in
            guard let label = Self.firstString(object, keys: ["label", "title", "text", "value"]) else {
                return nil
            }
            let id = Self.firstString(object, keys: ["id", "key"]) ?? label
            let value = Self.firstString(object, keys: ["value", "answer"]) ?? label
            let description = Self.firstString(object, keys: ["description", "detail", "subtitle"])
            return QuestionOption(id: id, label: label, value: value, description: description)
        }
    }

    private static func firstString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
