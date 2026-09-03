import Foundation
import VibeBuddyKit

/// One subagent a Grok session spawned, as recorded by the parent.
public struct GrokSubagent: Equatable, Sendable {
    public let id: String
    public let type: String?
    public let detail: String?
    public let finished: Bool
    public let startedAt: Date?

    public init(id: String, type: String? = nil, detail: String? = nil,
                finished: Bool = false, startedAt: Date? = nil) {
        self.id = id
        self.type = type
        self.detail = detail
        self.finished = finished
        self.startedAt = startedAt
    }
}

/// Reads a Grok Build session directory (`~/.grok/sessions/<cwd>/<id>/`) into
/// the same `TranscriptInfo` / `TranscriptEntry` shapes the Claude transcript
/// path produces, so one enrichment step serves both agents.
///
/// **One source per fact** (the discipline `agent-session-kit`'s
/// `GrokRecordMapper` documents — every interesting fact appears in at least
/// two of a session's files, so each is read out of exactly one):
///
/// | Fact | Read from |
/// | --- | --- |
/// | model, branch, title | `summary.json` |
/// | context window | `signals.json.contextWindowTokens` |
/// | live context size | newest `updates` `_meta.totalTokens`, else `signals.contextTokensUsed` |
/// | per-turn token spend | the newest `turn_completed.usage` |
/// | the model's prose | `updates` `agent_message_chunk`, else `summary.last_turn_summary` |
/// | tool lifecycle | `updates` `tool_call` / `tool_call_update` |
/// | permission block | `events.jsonl` `permission_requested` / `permission_resolved` |
/// | subagents | `subagents/<id>/meta.json`, plus `updates` `subagent_*` |
///
/// Every `.jsonl` read is a bounded **tail**: `agent-sessions`'
/// `GrokSessionParser` warns that `updates.jsonl` reaches gigabytes because
/// `tool_call_update` repeats a tool's accumulated output, and sessions on this
/// machine are already megabytes after a single turn.
public enum GrokSessionReader {

    /// `events.jsonl` holds one small record per line; this matches
    /// `TranscriptReader.recentEntries`' window.
    public static let tailBytes = 262_144
    /// `updates.jsonl` gets a wider window: a single `tool_call_update` carries a
    /// tool's accumulated output and routinely exceeds 256 KB, which would leave
    /// the tail holding no complete record at all.
    public static let updatesTailBytes = 1_048_576
    /// `summary.json` and `signals.json` are rewritten in place and stay small;
    /// this cap only bounds a corrupted or hostile file.
    static let objectBytes = 1_048_576

    // MARK: - Public reads

    /// Everything the dashboard shows for a session, plus the children the
    /// parent recorded — both out of one pass over the `updates.jsonl` tail.
    public struct Snapshot: Sendable {
        public let info: TranscriptInfo
        public let subagents: [GrokSubagent]
    }

    /// Reads a session directory, or nil when it holds none of Grok's session
    /// files.
    public static func read(directory: URL, summaryLimit: Int = 220,
                            maxBytes: Int = updatesTailBytes) -> Snapshot? {
        let summary = object(at: directory.appendingPathComponent("summary.json"))
        let signals = object(at: directory.appendingPathComponent("signals.json"))
        let updates = tail(at: directory.appendingPathComponent("updates.jsonl"), maxBytes: maxBytes)
        let events = tail(at: directory.appendingPathComponent("events.jsonl"),
                          maxBytes: tailBytes)
        guard summary != nil || signals != nil || updates != nil else { return nil }

        let facts = self.facts(updatesTail: updates ?? Data())
        var info = TranscriptInfo()

        info.model = string(summary, "current_model_id") ?? string(signals, "primaryModelId")
        info.branch = string(summary, "head_branch")

        // The newest `turn_completed` is one turn's cost, which the reducer
        // accumulates exactly like Claude's per-turn readings — keyed by the
        // turn's own id, so two turns that cost the same both count.
        info.tokens = facts.turnTokens
        info.tokensTurnID = facts.turnTokensID

        info.contextTokens = facts.contextTokens ?? int(signals, "contextTokensUsed")
        info.contextWindow = int(signals, "contextWindowTokens")

        info.summary = collapse(facts.lastAssistantText, limit: summaryLimit)
            ?? collapse(string(summary, "last_turn_summary"), limit: summaryLimit)
            ?? collapse(string(summary, "session_summary"), limit: summaryLimit)
            ?? collapse(string(summary, "generated_title"), limit: summaryLimit)

        info.activeTool = facts.runningTool
        info.pendingPermissionTool = pendingPermissionTool(eventsTail: events ?? Data())
        return Snapshot(info: info, subagents: subagents(directory: directory, facts: facts))
    }

    /// The session's recent output for the phone's detail pane, oldest→newest.
    public static func recentEntries(directory: URL, limit: Int = 12,
                                     perEntryLimit: Int = 600,
                                     maxBytes: Int = updatesTailBytes) -> [TranscriptEntry] {
        guard let data = tail(at: directory.appendingPathComponent("updates.jsonl"),
                              maxBytes: maxBytes) else { return [] }
        return recentEntries(updatesTail: data, limit: limit, perEntryLimit: perEntryLimit)
    }

    /// The subagents this session spawned. `subagents/<id>/meta.json` is the
    /// durable record and survives the tail window; the log — already parsed for
    /// `facts` — adds any child spawned before its directory was written.
    static func subagents(directory: URL, facts: UpdatesFacts) -> [GrokSubagent] {
        var byID: [String: GrokSubagent] = [:]
        let root = directory.appendingPathComponent("subagents", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for child in children {
            guard let meta = object(at: child.appendingPathComponent("meta.json")) else { continue }
            let id = string(meta, "subagent_id") ?? child.lastPathComponent
            guard !id.isEmpty else { continue }
            let status = string(meta, "status")
            byID[id] = GrokSubagent(
                id: id,
                type: string(meta, "subagent_type"),
                detail: string(meta, "description"),
                finished: status != nil && status != "running",
                startedAt: date(string(meta, "started_at")))
        }

        for spawn in facts.spawned where byID[spawn.id] == nil {
            byID[spawn.id] = GrokSubagent(id: spawn.id, type: spawn.type, detail: spawn.detail)
        }
        for id in facts.finished {
            guard let existing = byID[id], !existing.finished else { continue }
            byID[id] = GrokSubagent(id: id, type: existing.type, detail: existing.detail,
                                    finished: true, startedAt: existing.startedAt)
        }

        return byID.values.sorted {
            switch ($0.startedAt, $1.startedAt) {
            case let (a?, b?) where a != b: return a < b
            default: return $0.id < $1.id
            }
        }
    }

    // MARK: - Pure parsers over already-read bytes

    /// What one pass over an `updates.jsonl` tail establishes.
    struct UpdatesFacts {
        var lastAssistantText: String?
        /// The newest `turn_completed`'s input+output. Verified per-prompt, not
        /// cumulative: readings on a real four-turn session rise and fall, and
        /// each carries its own `numTurns` count of model calls.
        var turnTokens: Int?
        /// Which turn `turnTokens` was read off: `turn_completed.prompt_id`,
        /// falling back to the record's `_meta` identity. Without it the reducer
        /// cannot tell a re-read from a second turn of identical cost.
        var turnTokensID: String?
        var contextTokens: Int?
        var runningTool: String?
        var spawned: [(id: String, type: String?, detail: String?)] = []
        var finished: Set<String> = []
    }

    static func facts(updatesTail data: Data) -> UpdatesFacts {
        var facts = UpdatesFacts()
        var prose: [String] = []
        var openCalls: [(id: String, title: String)] = []

        for line in String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            // A tail cut mid-record simply fails to parse and is skipped.
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let params = root["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  let type = update["sessionUpdate"] as? String
            else { continue }

            let meta = params["_meta"] as? [String: Any]
            // The live context size rides on every turn-scoped record.
            if let total = int(meta, "totalTokens") {
                facts.contextTokens = total
            }

            switch type {
            case "user_message_chunk":
                prose.removeAll()
            case "agent_message_chunk":
                if let text = chunkText(update) { prose.append(text) }
            case "tool_call":
                // A tool call closes the model's current prose block, so what
                // survives is the newest message rather than the whole turn.
                prose.removeAll()
                guard let id = update["toolCallId"] as? String else { break }
                let title = (update["title"] as? String) ?? "tool"
                openCalls.removeAll { $0.id == id }
                openCalls.append((id, title))
            case "tool_call_update":
                // The variant without `status` is a mid-flight content append.
                guard let status = update["status"] as? String,
                      status == "completed" || status == "failed",
                      let id = update["toolCallId"] as? String else { break }
                openCalls.removeAll { $0.id == id }
            case "turn_completed":
                if let usage = update["usage"] as? [String: Any] {
                    facts.turnTokens = (int(usage, "inputTokens") ?? 0)
                        + (int(usage, "outputTokens") ?? 0)
                    // `prompt_id` names the turn; `_meta` is the backstop for a
                    // record written without one (its `eventId` is per-record,
                    // and one `turn_completed` is one turn either way).
                    facts.turnTokensID = string(update, "prompt_id")
                        ?? string(meta, "promptId")
                        ?? string(meta, "eventId")
                }
                openCalls.removeAll()
            case "subagent_spawned":
                guard let id = string(update, "subagent_id") else { break }
                facts.spawned.append((id, string(update, "subagent_type"),
                                      string(update, "description")))
            case "subagent_finished":
                if let id = string(update, "subagent_id") { facts.finished.insert(id) }
            default:
                continue
            }
        }

        facts.lastAssistantText = prose.isEmpty ? nil : prose.joined(separator: " ")
        facts.runningTool = openCalls.last?.title
        return facts
    }

    /// The tool whose permission prompt is still waiting. Grok writes no id on
    /// these records and shows one prompt at a time, so an unmatched request is
    /// simply the newer of the two record types.
    static func pendingPermissionTool(eventsTail data: Data) -> String? {
        var pending: String?
        for line in String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let type = record["type"] as? String else { continue }
            switch type {
            case "permission_requested": pending = string(record, "tool_name") ?? "a tool"
            case "permission_resolved": pending = nil
            default: continue
            }
        }
        return pending
    }

    static func recentEntries(updatesTail data: Data, limit: Int = 12,
                              perEntryLimit: Int = 600) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        var pending: (role: String, parts: [String])?

        func flush() {
            guard let open = pending else { return }
            pending = nil
            guard let text = collapse(open.parts.joined(separator: " "), limit: perEntryLimit)
            else { return }
            entries.append(TranscriptEntry(role: open.role, text: text))
        }
        func append(_ role: String, _ text: String) {
            if pending?.role != role { flush(); pending = (role, []) }
            pending?.parts.append(text)
        }

        for line in String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let params = root["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  let type = update["sessionUpdate"] as? String
            else { continue }

            switch type {
            case "user_message_chunk":
                if let text = chunkText(update) { append("user", text) }
            case "agent_message_chunk":
                if let text = chunkText(update) { append("assistant", text) }
            case "tool_call":
                // Same compact marker Claude's reader emits for a tool-only turn.
                flush()
                entries.append(TranscriptEntry(
                    role: "assistant", text: "⚙ \((update["title"] as? String) ?? "tool")"))
            default:
                // Reasoning, tool output, hook telemetry: noise for this pane.
                continue
            }
        }
        flush()
        return Array(entries.suffix(limit))
    }

    // MARK: - Helpers

    /// The last `maxBytes` of a file, or nil when it cannot be read.
    static func tail(at url: URL, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    static func object(at url: URL) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: objectBytes), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `{"content":{"type":"text","text":…}}` on every message chunk.
    private static func chunkText(_ update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any],
              let text = content["text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func string(_ object: [String: Any]?, _ key: String) -> String? {
        guard let value = object?[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func int(_ object: [String: Any]?, _ key: String) -> Int? {
        guard let value = object?[key] else { return nil }
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    /// Collapse whitespace runs and truncate; nil when nothing is left.
    private static func collapse(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(limit))
    }
}
