import Foundation
import CryptoKit

/// Reads only the transcript selected by the repository. Never invokes an agent.
enum SessionHistoryParser {
    static let byteLimit = 32 * 1024 * 1024
    static func read(url: URL, agent: SessionHistoryAgent, updatedAt: Date) throws -> SessionHistorySession {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        var warnings: [String] = []
        var content = data
        if content.count > byteLimit {
            content = content.prefix(byteLimit)
            if let end = content.lastIndex(of: 10) { content = content.prefix(through: end) }
            warnings.append("Partial history: source exceeds the 32 MiB reading limit.")
        }
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var nativeID = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var messages: [SessionHistoryMessage] = []
        var fallback: [SessionHistoryMessage] = []
        var seen = Set<String>()
        var order: [String: Int] = [:]
        var occurrences: [String: Int] = [:]
        var malformed = 0
        var omitted = 0
        func stamp(_ value: Any?) -> Date? { guard let text = value as? String else { return nil }; return fractional.date(from: text) ?? iso.date(from: text) }
        func string(_ value: Any?) -> String {
            if let text = value as? String { return text }
            guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
        func textBlocks(_ value: Any?) -> String {
            if let text = value as? String { return text }
            return (value as? [[String: Any]] ?? []).compactMap { block in
                if let text = block["text"] as? String { return text }
                if ["image", "input_image"].contains(block["type"] as? String ?? "") { omitted += 1; return "[Image attachment not rendered]" }
                return nil
            }.joined(separator: "\n\n")
        }
        for (lineNumber, line) in content.split(separator: 10).enumerated() {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { malformed += 1; continue }
            if agent == .claude, root["isSidechain"] as? Bool == true { omitted += 1; continue }
            let date = stamp(root["timestamp"])
            let type = root["type"] as? String ?? ""
            if let path = root["cwd"] as? String { cwd = path }
            if agent == .claude, let id = root["sessionId"] as? String { nativeID = id }
            func append(_ role: SessionHistoryRole, _ text: String, _ suffix: String, _ tool: String? = nil, fallbackOnly: Bool = false) {
                guard !text.isEmpty else { return }
                let material = role.rawValue + "\u{0}" + (tool ?? "") + "\u{0}" + suffix + "\u{0}" + text
                let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
                let key: String
                if let uuid = root["uuid"] as? String {
                    key = uuid + ":" + suffix + ":" + digest
                } else {
                    let ordinal = occurrences[digest, default: 0]
                    occurrences[digest] = ordinal + 1
                    key = "content:" + digest + ":" + String(ordinal)
                }
                guard seen.insert(key).inserted else { return }
                let bounded = String(text.prefix(128 * 1024))
                if bounded.count < text.count { omitted += 1 }
                order[key] = lineNumber
                let message = SessionHistoryMessage(id: key, role: role, text: bounded, timestamp: date, toolName: tool)
                if fallbackOnly { fallback.append(message) } else { messages.append(message) }
            }
            if agent == .claude {
                guard let body = root["message"] as? [String: Any], let role = SessionHistoryRole(rawValue: body["role"] as? String ?? type) else { continue }
                if let blocks = body["content"] as? [[String: Any]] {
                    for (index, block) in blocks.enumerated() {
                        switch block["type"] as? String {
                        case "text": append(role, block["text"] as? String ?? "", "\(index)")
                        case "tool_use": append(.tool, string(block["input"]), "\(index)", block["name"] as? String)
                        case "tool_result": append(.tool, textBlocks(block["content"]), "\(index)", "Result")
                        case "thinking", "redacted_thinking": omitted += 1
                        case "image": append(role, "[Image attachment not rendered]", "\(index)"); omitted += 1
                        default: omitted += 1
                        }
                    }
                } else { append(role, textBlocks(body["content"]), "0") }
            } else if let body = root["payload"] as? [String: Any] {
                if type == "session_meta" {
                    nativeID = body["id"] as? String ?? nativeID
                    cwd = body["cwd"] as? String ?? cwd
                } else if type == "turn_context", cwd.isEmpty { cwd = body["cwd"] as? String ?? cwd }
                else if type == "response_item" {
                    switch body["type"] as? String {
                    case "message":
                        if let role = SessionHistoryRole(rawValue: body["role"] as? String ?? "") {
                            if body["channel"] as? String == "analysis" { omitted += 1 }
                            else { append(role, textBlocks(body["content"]), "message") }
                        }
                    case "function_call", "custom_tool_call", "local_shell_call", "mcp_tool_call":
                        append(.tool, string(body["arguments"] ?? body["input"] ?? body["action"] ?? "[Tool call]"), "call", body["name"] as? String ?? "Tool")
                    case "function_call_output", "custom_tool_call_output": append(.tool, string(body["output"]), "output", "Result")
                    case "reasoning": omitted += 1
                    default: omitted += 1
                    }
                } else if type == "event_msg" {
                    let event = body["type"] as? String
                    if event == "user_message" || event == "agent_message" {
                        append(event == "user_message" ? .user : .assistant, body["message"] as? String ?? "", "event", fallbackOnly: true)
                    }
                }
            }
        }
        // Pair only neighboring semantic messages. A global text count can consume
        // an older, event-only "continue" when a later turn has a canonical mirror.
        if !fallback.isEmpty {
            var paired = Set<String>()
            let eventIDs = Set(fallback.map(\.id))
            let semantic = (messages + fallback).filter { $0.role == .user || $0.role == .assistant }
                .sorted { order[$0.id, default: 0] < order[$1.id, default: 0] }
            for (index, canonical) in semantic.enumerated() where !eventIDs.contains(canonical.id) {
                let canonicalLine = order[canonical.id, default: 0]
                let candidates = [index - 1, index + 1].compactMap { neighbor -> SessionHistoryMessage? in
                    guard semantic.indices.contains(neighbor) else { return nil }
                    let event = semantic[neighbor]
                    guard eventIDs.contains(event.id), !paired.contains(event.id), event.role == canonical.role, event.text == canonical.text else { return nil }
                    let eventLine = order[event.id, default: 0]
                    if let a = canonical.timestamp, let b = event.timestamp {
                        guard abs(a.timeIntervalSince(b)) <= 5 else { return nil }
                    } else if abs(eventLine - canonicalLine) > 12 { return nil }
                    return event
                }
                if candidates.count == 2,
                   abs(order[candidates[0].id, default: 0] - canonicalLine) == abs(order[candidates[1].id, default: 0] - canonicalLine) { continue }
                if let mirror = candidates.min(by: {
                    abs(order[$0.id, default: 0] - canonicalLine) < abs(order[$1.id, default: 0] - canonicalLine)
                }) { paired.insert(mirror.id) }
            }
            messages.append(contentsOf: fallback.filter { !paired.contains($0.id) })
            messages.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
        }
        if malformed > 0 { warnings.append("Partial history: \(malformed) malformed or incomplete JSONL records.") }
        if omitted > 0 { warnings.append("\(omitted) reasoning, attachment, unsupported or oversized blocks omitted/abbreviated.") }
        if messages.isEmpty { warnings.append("No readable messages in this source.") }
        let title = messages.first(where: { $0.role == .user })?.text.components(separatedBy: .newlines).first ?? nativeID
        return SessionHistorySession(id: agent.rawValue + ":" + nativeID, nativeSessionID: nativeID, agent: agent, projectPath: cwd, title: String(title.prefix(120)), sourcePath: url.path, updatedAt: updatedAt, messages: messages, warnings: warnings)
    }
}
