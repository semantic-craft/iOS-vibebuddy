import Foundation
import VibeBuddyKit

/// Pure mapping from Codex app-server notifications to the normalized
/// `HookEvent`s the session reducer already speaks. Keeps only what an event
/// needs from earlier ones — each thread's cwd, origin and load state — so the
/// monitor can replay a recorded notification stream through it in tests.
///
/// Facts, not guesses: a thread is *working* on `turn/started` or an `active`
/// status, *waiting* on an `active` status whose flags name a pending approval
/// or user-input request, and *done* on `turn/completed` or an `idle` status.
/// A `notLoaded` thread is history and surfaces nothing.
public struct CodexAppServerReducer: Sendable, Equatable {
    public struct ThreadFacts: Sendable, Equatable {
        public var cwd: String?
        /// Desktop stamps `source: "vscode"`; the TUI stamps `cli`. Desktop
        /// threads jump through `codex://threads/<id>`, so the id rides along.
        public var isDesktop: Bool
        public var branch: String?
        public var model: String?
        public var loaded: Bool
        /// The running turn, when the daemon has named one. `turn/steer`
        /// sends it as `expectedTurnId` so a late steer cannot attach to
        /// a later turn.
        public var activeTurnID: String?
    }

    public private(set) var threads: [String: ThreadFacts] = [:]
    private var tokenUpdateCount = 0
    private struct FinalItem: Sendable, Equatable { let turnID: String; let text: String }
    private var finalItems: [String: FinalItem] = [:]
    private struct Ending: Sendable, Equatable { let turnID: String; let at: Date }
    private var endings: [String: Ending] = [:]

    public init() {}

    /// The `thread` object of `thread/list`, `thread/started` or a
    /// `thread/resume` result. Returns the events that surface it — none for a
    /// stored-only (`notLoaded`) thread or a spawned subagent's own thread.
    public mutating func seed(thread: [String: Any], receivedAt: Date) -> [HookEvent] {
        guard let id = thread["id"] as? String, !id.isEmpty else { return [] }
        if Self.isSubagentThread(thread) { return [] }
        let source = Self.sourceName(thread["source"])
        var facts = threads[id] ?? ThreadFacts(cwd: nil, isDesktop: false, branch: nil, model: nil, loaded: false, activeTurnID: nil)
        if let cwd = thread["cwd"] as? String, !cwd.isEmpty { facts.cwd = cwd }
        facts.isDesktop = source == "vscode"
        if let git = thread["gitInfo"] as? [String: Any], let branch = git["branch"] as? String, !branch.isEmpty {
            facts.branch = branch
        }
        let status = thread["status"] as? [String: Any]
        facts.loaded = (status?["type"] as? String).map { $0 != "notLoaded" } ?? false
        if (status?["type"] as? String) == "idle" { facts.activeTurnID = nil }
        threads[id] = facts
        guard facts.loaded, let status else { return [] }
        let events = statusEvents(threadID: id, status: status, receivedAt: receivedAt, includeBranch: true)
        guard let path = thread["path"] as? String, !path.isEmpty else { return events }
        return events.map { $0.withTranscriptPath(path) }
    }

    /// One server message. Notifications become events; a server-initiated
    /// request (it carries an `id`) surfaces nothing and is reported through
    /// `serverRequestMethod` so the monitor can log what the daemon routes here.
    public mutating func handle(_ message: [String: Any], receivedAt: Date) -> [HookEvent] {
        guard let method = message["method"] as? String, message["id"] == nil else { return [] }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "thread/started":
            guard let thread = params["thread"] as? [String: Any] else { return [] }
            return seed(thread: thread, receivedAt: receivedAt)
        case "thread/status/changed":
            guard let id = params["threadId"] as? String, let status = params["status"] as? [String: Any] else { return [] }
            var facts = threads[id] ?? ThreadFacts(cwd: nil, isDesktop: false, branch: nil, model: nil, loaded: false, activeTurnID: nil)
            facts.loaded = (status["type"] as? String) != "notLoaded"
            if (status["type"] as? String) == "idle" { facts.activeTurnID = nil }
            threads[id] = facts
            guard facts.loaded else { return [] }
            return statusEvents(threadID: id, status: status, receivedAt: receivedAt, includeBranch: false)
        case "turn/started":
            guard let id = params["threadId"] as? String else { return [] }
            let turn = params["turn"] as? [String: Any]
            finalItems[id] = nil
            endings[id] = nil
            if let turnID = turn?["id"] as? String {
                var facts = threads[id] ?? ThreadFacts(cwd: nil, isDesktop: false, branch: nil, model: nil, loaded: true, activeTurnID: nil)
                facts.activeTurnID = turnID
                facts.loaded = true
                threads[id] = facts
            }
            return [event(.userPromptSubmit, threadID: id, receivedAt: receivedAt,
                          turnID: turn?["id"] as? String)]
        case "turn/completed":
            guard let id = params["threadId"] as? String else { return [] }
            threads[id]?.activeTurnID = nil
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String ?? "completed"
            if turn["status"] as? String == "completed", let turnID = turn["id"] as? String {
                if endings[id]?.turnID != turnID { endings[id] = Ending(turnID: turnID, at: receivedAt) }
            } else { endings[id] = nil }
            let message: String?
            switch status {
            case "failed":
                let detail = (turn["error"] as? [String: Any])?["message"] as? String
                message = "Turn failed" + (detail.map { ": \($0)" } ?? "")
            case "interrupted":
                message = "Turn interrupted"
            default:
                message = Self.fullLastAgentMessage(in: turn["items"] as? [[String: Any]] ?? [])
                    ?? (finalItems[id]?.turnID == turn["id"] as? String ? finalItems[id]?.text : nil)
            }
            return [event(.stop, threadID: id, receivedAt: receivedAt, message: message?.trimmingCharacters(in: .whitespacesAndNewlines),
                          turnID: turn["id"] as? String,
                          completionText: status == "completed" && turn["status"] != nil
                            ? message : nil, completionSucceeded: turn["status"] as? String == "completed")]
        case "item/started", "item/completed":
            if method == "item/completed", let id = params["threadId"] as? String,
               let turnID = params["turnId"] as? String,
               let item = params["item"] as? [String: Any],
               let text = Self.fullLastAgentMessage(in: [item]) {
                // Keep at most one character beyond the rejection limit. Such
                // a value is only rejected, never emitted as a truncated result.
                finalItems[id] = FinalItem(turnID: turnID, text: String(text.prefix(12_001)))
                if let ending = endings[id], ending.turnID == turnID {
                    return [event(.stop, threadID: id, receivedAt: ending.at,
                                  turnID: turnID, completionText: String(text.prefix(12_001)),
                                  completionSucceeded: true)]
                }
                return []
            }
            guard let id = params["threadId"] as? String,
                  let item = params["item"] as? [String: Any],
                  let tool = Self.toolName(for: item) else { return [] }
            if method == "item/started" {
                return [event(.preToolUse, threadID: id, receivedAt: receivedAt, toolName: tool,
                              turnID: params["turnId"] as? String)]
            }
            let failed = item["status"] as? String == "failed"
            return [event(.postToolUse, threadID: id, receivedAt: receivedAt, toolName: tool,
                          toolError: failed, turnID: params["turnId"] as? String)]
        case "thread/tokenUsage/updated":
            guard let id = params["threadId"] as? String,
                  let usage = params["tokenUsage"] as? [String: Any] else { return [] }
            // Same bookkeeping as the rollout's `token_count`: `last` is the
            // newest request's usage, counted once per update into spend, and
            // context occupancy leaves out the reasoning tokens.
            let last = usage["last"] as? [String: Any]
            guard let lastTotal = Self.int(last?["totalTokens"]) else { return [] }
            tokenUpdateCount += 1
            let info = TranscriptInfo(
                tokens: lastTotal,
                tokensTurnID: "tokenUsage:\(tokenUpdateCount)",
                contextTokens: lastTotal - (Self.int(last?["reasoningOutputTokens"]) ?? 0),
                contextWindow: Self.int(usage["modelContextWindow"]))
            return [event(.sessionMetadataChanged, threadID: id, receivedAt: receivedAt, enrichment: info)]
        case "thread/deleted", "thread/archived":
            // Gone from the daemon's list: the row goes with it.
            guard let id = params["threadId"] as? String, threads.removeValue(forKey: id) != nil else { return [] }
            finalItems[id] = nil
            endings[id] = nil
            return [event(.sessionEnd, threadID: id, receivedAt: receivedAt)]
        case "thread/closed":
            // Unloaded from memory (no subscribers, idle) — the session is not
            // over, only quiet. Later notifications re-seed it.
            if let id = params["threadId"] as? String { threads[id]?.loaded = false; finalItems[id] = nil; endings[id] = nil }
            return []
        case "error":
            guard let id = params["threadId"] as? String,
                  params["willRetry"] as? Bool != true else { return [] }
            let detail = (params["error"] as? [String: Any])?["message"] as? String
            endings[id] = nil
            finalItems[id] = nil
            return [event(.stop, threadID: id, receivedAt: receivedAt,
                          message: "Error" + (detail.map { ": \($0)" } ?? ""),
                          turnID: params["turnId"] as? String, completionSucceeded: false)]
        default:
            return []
        }
    }

    /// The method of a server-initiated request (`id` + `method`), else nil.
    public static func serverRequestMethod(_ message: [String: Any]) -> String? {
        guard message["id"] != nil, let method = message["method"] as? String else { return nil }
        return method
    }

    // MARK: - Mapping

    private func statusEvents(threadID: String, status: [String: Any], receivedAt: Date,
                              includeBranch: Bool) -> [HookEvent] {
        let branch = includeBranch ? threads[threadID]?.branch : nil
        let enrichment = branch.map { TranscriptInfo(branch: $0) }
        switch status["type"] as? String {
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            var events = [event(.userPromptSubmit, threadID: threadID, receivedAt: receivedAt,
                                enrichment: enrichment)]
            if flags.contains("waitingOnApproval") {
                events.append(event(.notification, threadID: threadID, receivedAt: receivedAt,
                                    message: "Permission required"))
            } else if flags.contains("waitingOnUserInput") {
                events.append(event(.notification, threadID: threadID, receivedAt: receivedAt,
                                    message: "Waiting for your input"))
            }
            return events
        case "idle":
            return [event(.sessionStart, threadID: threadID, receivedAt: receivedAt, enrichment: enrichment)]
        case "systemError":
            return [event(.stop, threadID: threadID, receivedAt: receivedAt,
                          message: "Codex failed with a system error", enrichment: enrichment, completionSucceeded: false)]
        default:
            return []
        }
    }

    private func event(_ kind: HookEvent.Kind, threadID: String, receivedAt: Date,
                       toolName: String? = nil, message: String? = nil,
                       toolError: Bool = false, turnID: String? = nil,
                       enrichment: TranscriptInfo? = nil, completionText: String? = nil, completionSucceeded: Bool? = nil) -> HookEvent {
        let facts = threads[threadID]
        return HookEvent(
            kind: kind,
            sessionID: threadID,
            agent: .codex,
            cwd: facts?.cwd,
            toolName: toolName,
            message: message,
            model: facts?.model,
            observationSource: .appserver,
            toolError: toolError,
            timestamp: receivedAt,
            turnID: turnID,
            enrichment: enrichment,
            desktopThreadID: facts?.isDesktop == true ? threadID : nil,
            completionText: completionText, completionSucceeded: completionSucceeded)
    }

    static func toolName(for item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "commandExecution": return "Shell"
        case "fileChange": return "Patch"
        case "mcpToolCall":
            let server = item["server"] as? String ?? "mcp"
            let tool = item["tool"] as? String ?? "tool"
            return "\(server)/\(tool)"
        case "dynamicToolCall": return item["tool"] as? String ?? "Tool"
        case "webSearch": return "Web search"
        case "imageGeneration": return "Image generation"
        case "collabAgentToolCall": return item["tool"] as? String ?? "Agents"
        default: return nil
        }
    }

    static func lastAgentMessage(in items: [[String: Any]]) -> String? {
        fullLastAgentMessage(in: items)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fullLastAgentMessage(in items: [[String: Any]]) -> String? {
        items.last(where: { $0["type"] as? String == "agentMessage"
            && ($0["phase"] == nil || $0["phase"] as? String == "final_answer") })
            .flatMap { $0["text"] as? String }
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// `source` is a bare string (`cli`, `vscode`) or an object keyed by the
    /// variant (`{custom: …}`, `{subAgent: …}`).
    static func sourceName(_ value: Any?) -> String {
        if let s = value as? String { return s.lowercased() }
        if let o = value as? [String: Any], let key = o.keys.first { return key.lowercased() }
        return ""
    }

    static func isSubagentThread(_ thread: [String: Any]) -> Bool {
        if sourceName(thread["source"]) == "subagent" { return true }
        if let threadSource = thread["threadSource"] {
            if let s = threadSource as? String { return s.lowercased() == "subagent" }
            if let o = threadSource as? [String: Any] { return o.keys.contains { $0.lowercased() == "subagent" } }
        }
        return false
    }


    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let d as Double: return Int(d)
        default: return nil
        }
    }
}
