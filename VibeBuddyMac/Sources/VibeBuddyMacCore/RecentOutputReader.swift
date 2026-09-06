import Foundation
import VibeBuddyKit

/// One bounded pass over an already-read source. Pure — no I/O.
public struct RecentOutputSlice: Equatable, Sendable {
    public var entries: [TranscriptEntry]
    public var truncated: Bool
    public var updatedAt: Date?

    public init(entries: [TranscriptEntry], truncated: Bool = false, updatedAt: Date? = nil) {
        self.entries = entries
        self.truncated = truncated
        self.updatedAt = updatedAt
    }
}

/// Per-agent dialogue extractors for the phone's recent-output pane.
///
/// Each adapter knows one on-disk / wire shape. Thinking, full tool results,
/// images, and terminal dumps are dropped; a tool-only turn collapses to a
/// compact "⚙ name" marker, same as the Mac detail pane.
public enum RecentOutputReader {

    public static func claude(tail data: Data, limit: Int = 12,
                              perEntryLimit: Int = 600) -> RecentOutputSlice {
        bound(TranscriptReader.recentEntries(tail: data, limit: .max, perEntryLimit: .max),
              limit: limit, perEntryLimit: perEntryLimit)
    }

    public static func grok(updatesTail data: Data, limit: Int = 12,
                            perEntryLimit: Int = 600) -> RecentOutputSlice {
        bound(GrokSessionReader.recentEntries(updatesTail: data, limit: .max,
                                              perEntryLimit: .max),
              limit: limit, perEntryLimit: perEntryLimit)
    }

    public static func codexRollout(tail data: Data, limit: Int = 12,
                                    perEntryLimit: Int = 600) -> RecentOutputSlice {
        var entries: [TranscriptEntry] = []
        var newest: Date?
        for line in String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any] else { continue }
            if let stamp = timestamp(root["timestamp"] as? String) { newest = stamp }
            guard let entry = codexRolloutEntry(root) else { continue }
            if entry.role == "assistant",
               entries.last?.role == "assistant",
               entries.last?.text == entry.text {
                continue
            }
            entries.append(entry)
        }
        var slice = bound(entries, limit: limit, perEntryLimit: perEntryLimit)
        slice.updatedAt = newest
        return slice
    }

    public static func codexAppServer(items: [[String: Any]], limit: Int = 12,
                                      perEntryLimit: Int = 600) -> RecentOutputSlice {
        var entries: [TranscriptEntry] = []
        for item in items {
            guard let entry = codexAppServerEntry(item) else { continue }
            entries.append(entry)
        }
        return bound(entries, limit: limit, perEntryLimit: perEntryLimit)
    }

    // MARK: - Codex rollout

    private static func codexRolloutEntry(_ root: [String: Any]) -> TranscriptEntry? {
        let type = root["type"] as? String
        if type == "response_item", let payload = root["payload"] as? [String: Any] {
            return codexResponseItem(payload)
        }
        if type == "event_msg", let payload = root["payload"] as? [String: Any] {
            return codexEventMessage(payload)
        }
        return nil
    }

    private static func codexResponseItem(_ payload: [String: Any]) -> TranscriptEntry? {
        let itemType = payload["type"] as? String
        switch itemType {
        case "message":
            guard let role = payload["role"] as? String, role == "user" || role == "assistant",
                  let text = collapse(codexMessageText(payload["content"]))
            else { return nil }
            return TranscriptEntry(role: role, text: text)
        case "function_call", "custom_tool_call", "local_shell_call", "mcp_tool_call":
            return TranscriptEntry(role: "assistant", text: "⚙ \(codexToolName(payload, itemType: itemType))")
        default:
            return nil
        }
    }

    private static func codexEventMessage(_ payload: [String: Any]) -> TranscriptEntry? {
        switch payload["type"] as? String {
        case "user_message":
            return collapse(payload["message"] as? String ?? payload["text"] as? String)
                .map { TranscriptEntry(role: "user", text: $0) }
        case "agent_message":
            return collapse(payload["message"] as? String ?? payload["text"] as? String)
                .map { TranscriptEntry(role: "assistant", text: $0) }
        case "task_complete":
            return collapse(payload["last_agent_message"] as? String)
                .map { TranscriptEntry(role: "assistant", text: $0) }
        default:
            return nil
        }
    }

    private static func codexMessageText(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return nil }
        var parts: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text", "input_text", "output_text":
                if let text = block["text"] as? String { parts.append(text) }
            default:
                continue
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func codexToolName(_ payload: [String: Any], itemType: String?) -> String {
        let name = (payload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let namespace = (payload["namespace"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [namespace, name].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: "/") }
        return itemType == "local_shell_call" ? "Shell" : "Tool"
    }

    // MARK: - Codex app-server items

    private static func codexAppServerEntry(_ item: [String: Any]) -> TranscriptEntry? {
        switch item["type"] as? String {
        case "userMessage":
            return collapse(item["text"] as? String).map { TranscriptEntry(role: "user", text: $0) }
        case "agentMessage":
            return collapse(item["text"] as? String).map { TranscriptEntry(role: "assistant", text: $0) }
        default:
            return CodexAppServerReducer.toolName(for: item)
                .map { TranscriptEntry(role: "assistant", text: "⚙ \($0)") }
        }
    }

    // MARK: - Shared

    private static func bound(_ entries: [TranscriptEntry], limit: Int,
                              perEntryLimit: Int) -> RecentOutputSlice {
        var truncated = entries.count > limit
        let clipped = entries.suffix(limit).map { entry -> TranscriptEntry in
            if entry.text.count > perEntryLimit {
                truncated = true
                return TranscriptEntry(role: entry.role, text: String(entry.text.prefix(perEntryLimit)))
            }
            return entry
        }
        return RecentOutputSlice(entries: Array(clipped), truncated: truncated)
    }

    private static func collapse(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
