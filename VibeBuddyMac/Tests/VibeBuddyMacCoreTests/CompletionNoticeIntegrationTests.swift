import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

struct CompletionNoticeIntegrationTests {
    actor GenerationGate {
        var calls = 0
        var continuation: CheckedContinuation<String?, Never>?
        func generate() async -> String? {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(returning: "The drawing is ready."); continuation = nil }
    }

    @Test("notification generation waits for native settlement and cancels if continuation arrives during generation",
          arguments: [AgentKind.claudeCode, .cursor])
    func settledNotification(_ agent: AgentKind) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("source.jsonl")
        try Data().write(to: file)
        let store = SessionStore(sourceID: "native-notice")
        let gate = GenerationGate()
        await store.configureCompletionNotices(url: dir.appendingPathComponent("decisions.json"), enabled: { true }) { _ in
            await gate.generate()
        }
        func append(_ row: [String: Any]) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([10]))
        }
        let end = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: agent,
            transcriptPath: file.path, observationSource: .hook, timestamp: end.addingTimeInterval(-1)))
        _ = await store.setAttention(sessionID: "s", .followed)
        if agent == .claudeCode {
            try append(["type": "assistant", "sessionId": "s", "timestamp": formatter.string(from: end),
                "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "The drawing is ready."]]]])
        } else {
            try append(["role": "assistant", "message": ["content": [["type": "text", "text": "The drawing is ready."]]]])
        }
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: agent, transcriptPath: file.path,
            observationSource: .hook, timestamp: end,
            completionText: agent == .claudeCode ? "The drawing is ready." : nil, completionSucceeded: true))
        #expect(await store.snapshot(now: Date()).sessions.first?.completionNotice?.state == .pending)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await gate.calls == 0)
        if agent == .claudeCode {
            try append(["type": "system", "subtype": "stop_hook_summary", "sessionId": "s",
                "timestamp": formatter.string(from: end), "preventedContinuation": false,
                "stopReason": "", "hookAdditionalContext": [], "hookErrors": []])
        } else { try append(["type": "turn_ended", "status": "success"]) }
        for _ in 0..<100 where await gate.calls == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await gate.calls == 1)
        #expect(await store.snapshot(now: Date()).sessions.first?.completionNotice?.state == .pending)
        if agent == .claudeCode {
            try append(["type": "system", "subtype": "stop_hook_summary", "sessionId": "s",
                "timestamp": formatter.string(from: end), "preventedContinuation": false,
                "stopReason": "", "hookAdditionalContext": ["Continue working"], "hookErrors": []])
        } else { try append(["role": "user", "message": ["content": [["type": "text", "text": "Continue working"]]]]) }
        await gate.release()
        for _ in 0..<100 {
            if await store.snapshot(now: Date()).sessions.first?.completionNotice?.state == .cancelled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await store.snapshot(now: Date()).sessions.first?.completionNotice?.state == .cancelled)
    }

    @Test("an unverified completion expires without a plain completion reminder")
    func unverifiedDeadlineIsSilent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(sourceID: "unverified")
        let gate = GenerationGate()
        await store.configureCompletionNotices(url: dir.appendingPathComponent("decisions.json"), enabled: { true }) { _ in
            await gate.generate()
        }
        let end = Date().addingTimeInterval(-11.5)
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            observationSource: .hook, timestamp: end.addingTimeInterval(-1), turnID: "a"))
        _ = await store.setAttention(sessionID: "s", .followed)
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .hook, timestamp: end, turnID: "a"))
        #expect(await store.snapshot(now: Date()).sessions.first?.completionNotice?.state == .pending)
        try await Task.sleep(for: .milliseconds(700))
        #expect(await store.snapshot(now: Date()).sessions.first?.completionNotice?.state == .cancelled)
        #expect(await gate.calls == 0)
    }

    @Test func decisionSurvivesRestartAndCorruptionDoesNotOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("decisions.json")
        var ledger = CompletionNoticeLedger(url: file)
        let notice = CompletionNotice(id: "source/session/completion", deadline: Date().addingTimeInterval(12))
        let saved = ledger.save(notice)
        #expect(saved)
        let restored = CompletionNoticeLedger(url: file)
        #expect(restored.notices[notice.id]?.state == .plain)
        let broken = Data("broken".utf8)
        try broken.write(to: file)
        var corrupt = CompletionNoticeLedger(url: file)
        let overwritten = corrupt.save(notice)
        #expect(!overwritten)
        #expect(try Data(contentsOf: file) == broken)
    }
    @Test func storePublishesPendingBeforeResolvedCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(sourceID: "synthetic-source")
        await store.configureCompletionNotices(url: dir.appendingPathComponent("decisions.json"), enabled: { true }) { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return "Synthetic repair complete; device validation pending."
        }
        let t = Date()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex, timestamp: t.addingTimeInterval(-60), turnID: "turn"))
        _ = await store.setAttention(sessionID: "s", .followed)
        await store.ingest(HookEvent(kind: .stop, sessionID: "s", agent: .codex, timestamp: t, turnID: "turn", completionText: "Synthetic result", completionSucceeded: true))
        #expect(await store.snapshot(now: Date()).sessions.first?.completionNotice?.state == .pending)
        try await Task.sleep(for: .milliseconds(200))
        let s = try #require(await store.snapshot(now: Date()).sessions.first)
        #expect(s.completionNotice?.state == .summary)
        #expect(s.summary != s.completionNotice?.text)
    }
}
