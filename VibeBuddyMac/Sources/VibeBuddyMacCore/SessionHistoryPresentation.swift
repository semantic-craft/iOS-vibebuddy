import Foundation

public struct HistoryToolCall: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var input: String
    public var output: String?
    public var isError: Bool
    public var messageIDs: [String]
    public var preview: String {
        if let data = input.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["command", "cmd", "file_path", "path", "query", "q", "description"] {
                if let value = json[key] as? String { return Self.oneLine(value) }
            }
        }
        return Self.oneLine(input)
    }
    private static func oneLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
    }
}
public struct HistoryMessageRow: Identifiable, Sendable {
    public var id: String
    public var role: SessionHistoryRole
    public var kind: SessionHistoryMessageKind
    public var text = ""
    public var thinking = ""
    public var tools: [HistoryToolCall] = []
    public var messageIDs: [String] = []
    var groupID: String?
    public func contains(_ messageID: String?) -> Bool { messageID.map { messageIDs.contains($0) } ?? false }
}

/// A read-only presentation projection. Raw IDs remain addressable by search/export.
public enum SessionHistoryPresentation {
    public static func rows(_ messages: [SessionHistoryMessage], revealing target: String? = nil, includingThinking: Bool = false) -> [HistoryMessageRow] {
        var rows: [HistoryMessageRow] = []
        var calls: [String: (Int, Int)] = [:]
        for message in messages {
            let kind = message.kind ?? .text
            if message.role == .tool {
                if message.isToolOutput == true, let callID = message.toolCallID, let (row, tool) = calls[callID] {
                    let old = rows[row].tools[tool].output
                    rows[row].tools[tool].output = [old, message.text].compactMap { $0 }.joined(separator: "\n\n")
                    rows[row].tools[tool].isError = rows[row].tools[tool].isError || message.isError == true
                    rows[row].tools[tool].messageIDs.append(message.id)
                    rows[row].messageIDs.append(message.id)
                    continue
                }
                if rows.last?.role != .assistant || rows.last?.kind == .compactSummary || rows.last?.kind == .meta {
                    rows.append(HistoryMessageRow(id: message.id, role: .assistant, kind: .text))
                }
                let row = rows.count - 1
                let tool = HistoryToolCall(id: message.id, name: message.isToolOutput == true ? "Unmatched tool result" : message.toolName ?? "Tool",
                    input: message.isToolOutput == true ? "" : message.text,
                    output: message.isToolOutput == true ? message.text : nil, isError: message.isError == true, messageIDs: [message.id])
                rows[row].tools.append(tool); rows[row].messageIDs.append(message.id)
                if let id = message.toolCallID, message.isToolOutput != true { calls[id] = (row, rows[row].tools.count - 1) }
                if let group = message.groupID { rows[row].groupID = group }
                continue
            }
            let sameGroup = message.role == .assistant && message.groupID != nil && rows.last?.groupID == message.groupID
            let pendingThinking = message.role == .assistant && rows.last?.role == .assistant && rows.last?.text.isEmpty == true
                && rows.last?.tools.isEmpty == true && rows.last?.thinking.isEmpty == false
            if kind != .meta && kind != .compactSummary && (sameGroup || pendingThinking), !rows.isEmpty {
                let index = rows.count - 1
                if kind == .thinking { rows[index].thinking += (rows[index].thinking.isEmpty ? "" : "\n\n") + message.text }
                else { rows[index].text += (rows[index].text.isEmpty ? "" : "\n\n") + message.text }
                rows[index].messageIDs.append(message.id)
                if let group = message.groupID { rows[index].groupID = group }
            } else {
                rows.append(HistoryMessageRow(id: message.id, role: message.role, kind: kind,
                    text: kind == .thinking ? "" : message.text, thinking: kind == .thinking ? message.text : "",
                    messageIDs: [message.id], groupID: message.groupID))
            }
        }
        return rows.filter { row in
            if row.contains(target) { return true }
            if row.kind == .meta { return false }
            return row.kind == .compactSummary || !row.text.isEmpty || !row.tools.isEmpty || (includingThinking && !row.thinking.isEmpty)
        }
    }
}
