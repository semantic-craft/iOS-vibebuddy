import Foundation

/// Read-only task details. These values never enter SessionReducer or establish control authority.
public enum CodexReadFailure: Error, Equatable, Sendable {
    case disconnected, unsupported, unavailable, malformed
    public var message: String {
        switch self {
        case .disconnected: "Codex service is not connected."
        case .unsupported: "This Codex version does not support this view."
        case .unavailable: "Codex could not read this task."
        case .malformed: "Codex returned an unrecognized response."
        }
    }
    static func classify(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if let rpc = error as? CodexAppServerClient.ClientError {
            switch rpc {
            case .rpc(let code, _) where code == -32601 || code == -32602: return .unsupported
            case .closed: return .disconnected
            default: break
            }
        }
        return .unavailable
    }
}

public struct CodexTaskGoal: Decodable, Equatable, Sendable {
    public let threadId: String
    public let objective: String
    public let status: String
    public let tokensUsed: Int64
    public let tokenBudget: Int64?
    public let timeUsedSeconds: Int64
    public let updatedAt: Int64
}

public struct CodexBackgroundTerminal: Decodable, Equatable, Identifiable, Sendable {
    public let processId: String
    public let command: String
    public let cwd: String
    public let osPid: UInt32?
    public let cpuPercent: Double?
    public let rssKb: UInt64?
    public var id: String { processId }
}

public struct CodexTerminalPage: Decodable, Equatable, Sendable {
    public let data: [CodexBackgroundTerminal]
    public let nextCursor: String?
}

public struct CodexHistoryPage: Sendable {
    public let messages: [SessionHistoryMessage]
    public let nextCursor: String?

    /// The server returns newest first. Preserve item identity across overlapping pages.
    static func decode(_ response: [String: Any]) throws -> Self {
        guard let entries = response["data"] as? [[String: Any]],
              response["nextCursor"] == nil || response["nextCursor"] is NSNull || response["nextCursor"] is String else {
            throw CodexReadFailure.malformed
        }
        var messages: [SessionHistoryMessage] = []
        for entry in entries.reversed() {
            guard let item = entry["item"] as? [String: Any], let id = item["id"] as? String,
                  let type = item["type"] as? String, let turn = entry["turnId"] as? String else {
                throw CodexReadFailure.malformed
            }
            let key = turn + "/" + id
            let date = (entry["startedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            func append(_ role: SessionHistoryRole, _ text: String, kind: SessionHistoryMessageKind? = nil,
                        tool: String? = nil, suffix: String = "", output: Bool = false) {
                messages.append(.init(id: key + suffix, role: role, text: text, timestamp: date,
                                      toolName: tool, kind: kind, toolCallID: tool == nil ? nil : key,
                                      isToolOutput: output, isError: item["status"] as? String == "failed"))
            }
            switch type {
            case "userMessage":
                let content = item["content"] as? [[String: Any]] ?? []
                let text = content.map { ($0["text"] as? String) ?? "[\($0["type"] as? String ?? "attachment")]" }.joined(separator: "\n")
                append(.user, text)
            case "agentMessage": append(.assistant, item["text"] as? String ?? "")
            case "reasoning":
                let summary = (item["summary"] as? [String]) ?? []
                append(.assistant, summary.joined(separator: "\n"), kind: .thinking)
            case "contextCompaction": append(.system, "", kind: .compactSummary)
            case "commandExecution":
                append(.tool, item["command"] as? String ?? "", tool: "Command")
                if let output = item["aggregatedOutput"] as? String {
                    append(.tool, output, tool: "Command", suffix: "/output", output: true)
                }
            case "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch", "collabAgentToolCall":
                let data = try JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys])
                append(.tool, String(decoding: data, as: UTF8.self), tool: item["tool"] as? String ?? type)
            default:
                // Do not silently present a partial item as complete dialogue.
                append(.system, "[\(type)]")
            }
        }
        return .init(messages: messages, nextCursor: response["nextCursor"] as? String)
    }

    /// A live refresh keeps already loaded older pages only with an overlap anchor.
    /// Without an anchor, retaining both ranges could silently hide an unread gap.
    public static func refreshing(_ current: [SessionHistoryMessage], with latest: [SessionHistoryMessage])
        -> (messages: [SessionHistoryMessage], keptEarlier: Bool) {
        let ids = Set(current.map(\.id))
        let overlaps = latest.contains { ids.contains($0.id) }
        return (overlaps ? prepend(current, to: latest) : latest, overlaps)
    }

    public static func prepend(_ older: [SessionHistoryMessage], to current: [SessionHistoryMessage]) -> [SessionHistoryMessage] {
        let currentIDs = Set(current.map(\.id))
        var seen = Set<String>()
        return older.filter { !currentIDs.contains($0.id) && seen.insert($0.id).inserted } + current
    }
}

extension CodexAppServerMonitor {
    public func taskGoal(threadID: String) async -> Result<CodexTaskGoal?, CodexReadFailure> {
        do {
            let response = try await readRequest("thread/goal/get", params: ["threadId": threadID])
            guard let value = response["goal"] else { throw CodexReadFailure.malformed }
            if value is NSNull { return .success(nil) }
            let goal = try Self.decodeRead(CodexTaskGoal.self, from: value)
            guard goal.threadId == threadID else { throw CodexReadFailure.malformed }
            return .success(goal)
        } catch { return .failure(.classify(error)) }
    }

    public func backgroundTerminals(threadID: String, cursor: String? = nil) async -> Result<CodexTerminalPage, CodexReadFailure> {
        do {
            var params: [String: Any] = ["threadId": threadID, "limit": 50]
            if let cursor { params["cursor"] = cursor }
            let response = try await readRequest("thread/backgroundTerminals/list", params: params)
            return .success(try Self.decodeRead(CodexTerminalPage.self, from: response))
        } catch { return .failure(.classify(error)) }
    }

    public func historyPage(threadID: String, cursor: String? = nil) async -> Result<CodexHistoryPage, CodexReadFailure> {
        do {
            var params: [String: Any] = ["threadId": threadID, "limit": 30, "sortDirection": "desc"]
            if let cursor { params["cursor"] = cursor }
            return .success(try CodexHistoryPage.decode(await readRequest("thread/items/list", params: params)))
        } catch { return .failure(.classify(error)) }
    }

    private static func decodeRead<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value)) }
        catch { throw CodexReadFailure.malformed }
    }
}
