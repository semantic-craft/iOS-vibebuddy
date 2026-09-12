import Foundation
import Testing
@testable import VibeBuddyMacCore
import VibeBuddyKit

@Suite("Token consumption — Claude / Codex log aggregation")
struct TokenConsumptionScanTests {
    private let now = date("2026-07-21T12:00:00Z")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("Claude counts cache creation, keeps the first cwd, and drops zero-usage rows")
    func claudeCacheAndCwd() throws {
        let root = try makeRoot()
        try writeClaude(root, project: "-Users-dev-my-hyphen-project", session: "session-a", lines: [
            claudeUser("2026-07-21T10:00:00.000Z", cwd: "/Users/dev/my-hyphen-project"),
            claudeAssistant("2026-07-21T10:05:00.000Z", cwd: "/Users/dev/my-hyphen-project/packages/api",
                            model: "claude-opus-4-8", uuid: "usage-a",
                            usage: ["input_tokens": 11, "output_tokens": 7,
                                    "cache_read_input_tokens": 13,
                                    "cache_creation_input_tokens": 17,
                                    "cache_creation": ["ephemeral_5m_input_tokens": 5,
                                                       "ephemeral_1h_input_tokens": 12]]),
            claudeAssistant("2026-07-21T10:35:00.000Z", cwd: "/Users/dev/my-hyphen-project",
                            model: "<synthetic>", uuid: "synthetic-zero",
                            usage: ["input_tokens": 0, "output_tokens": 0]),
        ])
        let snap = TokenConsumptionScan.snapshot(
            claudeHomes: [root], codexHome: root.appendingPathComponent("empty-codex"),
            now: now, calendar: calendar)
        let today = try #require(snap.window(.today))
        #expect(today.counts.inputTokens == 28) // 11 + max(17, 5+12)
        #expect(today.counts.outputTokens == 7)
        #expect(today.counts.cachedInputTokens == 13)
        #expect(today.counts.sessionCount == 1)
        #expect(today.byProject.first?.label == "my-hyphen-project")
        #expect(today.byModel.first?.key == "claude-opus-4-8")
    }

    @Test("Claude streaming blocks that share a message id count once, keeping the higher usage")
    func claudeDedupeByMessageID() throws {
        let root = try makeRoot()
        try writeClaude(root, project: "-proj", session: "s1", lines: [
            claudeAssistant("2026-07-21T10:05:00.000Z", cwd: "/tmp/proj", model: "claude-sonnet-4-5",
                            uuid: "a", messageID: "msg-1", requestID: "req-1",
                            usage: ["input_tokens": 10, "output_tokens": 2]),
            claudeAssistant("2026-07-21T10:05:01.000Z", cwd: "/tmp/proj", model: "claude-sonnet-4-5",
                            uuid: "b", messageID: "msg-1", requestID: "req-1",
                            usage: ["input_tokens": 10, "output_tokens": 8]),
        ])
        let snap = TokenConsumptionScan.snapshot(
            claudeHomes: [root], codexHome: root.appendingPathComponent("empty-codex"),
            now: now, calendar: calendar)
        let today = try #require(snap.window(.today))
        #expect(today.counts.inputTokens == 10)
        #expect(today.counts.outputTokens == 8)
    }

    @Test("Codex last_token_usage is normalized and duplicate cumulative totals count once")
    func codexDuplicateAndCacheSplit() throws {
        let root = try makeRoot()
        try writeCodex(root, name: "rollout-a.jsonl", lines: [
            sessionMeta("2026-07-21T10:00:00.000Z", id: "a-1", cwd: "/Users/x/search-indexer"),
            event("2026-07-21T10:00:00.000Z", "task_started"),
            tokenCount("2026-07-21T10:01:00.000Z", last: usage(1000, cached: 200, output: 100, reasoning: 40), total: 1100),
            tokenCount("2026-07-21T10:01:00.000Z", last: usage(1000, cached: 200, output: 100, reasoning: 40), total: 1100),
            tokenCount("2026-07-21T10:05:00.000Z", last: usage(2000, cached: 0, output: 200, reasoning: 0), total: 3300),
        ])
        let snap = TokenConsumptionScan.snapshot(
            claudeHomes: [root.appendingPathComponent("empty-claude")],
            codexHome: root.appendingPathComponent(".codex"),
            now: now, calendar: calendar)
        let today = try #require(snap.window(.today))
        #expect(today.counts.inputTokens == 2800) // (1000-200) + 2000
        #expect(today.counts.outputTokens == 260) // (100-40) + 200
        #expect(today.counts.cachedInputTokens == 200)
        #expect(today.counts.reasoningOutputTokens == 40)
        #expect(today.byProject.first?.label == "search-indexer")
        #expect(today.byAgent.first?.key == AgentKind.codex.rawValue)
    }

    @Test("Codex turn_context names the model; cached_input_tokens is not summed with cache_read")
    func codexTurnContextAndCacheFallback() throws {
        let root = try makeRoot()
        try writeCodex(root, name: "rollout-b.jsonl", lines: [
            sessionMeta("2026-07-21T10:00:00.000Z", id: "b-1", cwd: "/Users/x/search-indexer"),
            json(["timestamp": "2026-07-21T10:00:01.000Z", "type": "turn_context",
                  "payload": ["model": "gpt-5.4"]]),
            json(["timestamp": "2026-07-21T10:01:00.000Z", "type": "event_msg",
                  "payload": ["type": "token_count",
                              "info": ["total_token_usage": ["total_tokens": 1500],
                                       "last_token_usage": ["input_tokens": 1200,
                                                            "cached_input_tokens": 200,
                                                            "cache_read_input_tokens": 200,
                                                            "output_tokens": 100,
                                                            "reasoning_output_tokens": 0]]]]),
        ])
        let snap = TokenConsumptionScan.snapshot(
            claudeHomes: [root.appendingPathComponent("empty-claude")],
            codexHome: root.appendingPathComponent(".codex"),
            now: now, calendar: calendar)
        let today = try #require(snap.window(.today))
        #expect(today.counts.inputTokens == 1000) // 1200 - 200, not 1200 - 400
        #expect(today.counts.cachedInputTokens == 200)
        #expect(today.byModel.first?.key == "gpt-5.4")
    }

    @Test("A copied parent block after a second session_meta is skipped until the child's task_started")
    func codexSkipsReplayedHistory() throws {
        let root = try makeRoot()
        try writeCodex(root, name: "rollout-child.jsonl", lines: [
            sessionMeta("2026-07-21T11:00:00.000Z", id: "child-1", cwd: "/Users/x/proj"),
            sessionMeta("2026-07-21T10:00:00.000Z", id: "parent-1", cwd: "/Users/x/proj"),
            tokenCount("2026-07-21T10:01:00.000Z", last: usage(5000, cached: 0, output: 500, reasoning: 0), total: 5500),
            event("2026-07-21T11:00:02.000Z", "task_started"),
            tokenCount("2026-07-21T11:01:00.000Z", last: usage(80, cached: 0, output: 20, reasoning: 0), total: 5600),
        ])
        let snap = TokenConsumptionScan.snapshot(
            claudeHomes: [root.appendingPathComponent("empty-claude")],
            codexHome: root.appendingPathComponent(".codex"),
            now: now, calendar: calendar)
        let today = try #require(snap.window(.today))
        #expect(today.counts.inputTokens == 80)
        #expect(today.counts.outputTokens == 20)
    }

    @Test("Older-than-today entries land in the 7-day window only")
    func windowsSplitByDay() throws {
        let entries = [
            TokenUsageEntry(agent: .claudeCode, model: "claude-opus-4-8", project: "a",
                            sessionID: "old", timestamp: date("2026-07-16T10:00:00Z"),
                            inputTokens: 100, outputTokens: 10, cachedInputTokens: 0, reasoningOutputTokens: 0),
            TokenUsageEntry(agent: .codex, model: "gpt-5-codex", project: "b",
                            sessionID: "new", timestamp: date("2026-07-21T10:00:00Z"),
                            inputTokens: 50, outputTokens: 5, cachedInputTokens: 0, reasoningOutputTokens: 0),
        ]
        let snap = TokenConsumptionAggregator.snapshot(entries: entries, now: now, calendar: calendar, warnings: [])
        #expect(snap.window(.today)?.counts.inputTokens == 50)
        #expect(snap.window(.today)?.counts.sessionCount == 1)
        #expect(snap.window(.last7Days)?.counts.inputTokens == 150)
        #expect(snap.window(.last7Days)?.counts.sessionCount == 2)
        #expect(snap.window(.last7Days)?.byAgent.count == 2)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vb-tokens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeClaude(_ root: URL, project: String, session: String, lines: [String]) throws {
        let dir = root.appendingPathComponent("projects/\(project)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
    }

    private func writeCodex(_ root: URL, name: String, lines: [String]) throws {
        let dir = root.appendingPathComponent(".codex/sessions/2026/07/21", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func claudeUser(_ timestamp: String, cwd: String) -> String {
        json(["type": "user", "timestamp": timestamp, "cwd": cwd])
    }

    private func claudeAssistant(
        _ timestamp: String, cwd: String, model: String, uuid: String,
        messageID: String? = nil, requestID: String? = nil, usage: [String: Any]
    ) -> String {
        var message: [String: Any] = ["role": "assistant", "model": model, "usage": usage]
        if let messageID { message["id"] = messageID }
        var obj: [String: Any] = ["type": "assistant", "timestamp": timestamp, "cwd": cwd,
                                  "uuid": uuid, "message": message]
        if let requestID { obj["requestId"] = requestID }
        return json(obj)
    }

    private func sessionMeta(_ timestamp: String, id: String, cwd: String) -> String {
        json(["timestamp": timestamp, "type": "session_meta",
              "payload": ["id": id, "cwd": cwd, "timestamp": timestamp]])
    }

    private func event(_ timestamp: String, _ type: String) -> String {
        json(["timestamp": timestamp, "type": "event_msg", "payload": ["type": type]])
    }

    private func tokenCount(_ timestamp: String, last: [String: Int], total: Int) -> String {
        json(["timestamp": timestamp, "type": "event_msg",
              "payload": ["type": "token_count",
                          "info": ["model": "gpt-5.2",
                                   "total_token_usage": ["total_tokens": total],
                                   "last_token_usage": last]]])
    }

    private func usage(_ input: Int, cached: Int, output: Int, reasoning: Int) -> [String: Int] {
        ["input_tokens": input, "cached_input_tokens": cached,
         "output_tokens": output, "reasoning_output_tokens": reasoning,
         "total_tokens": input + output]
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

private func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
}
