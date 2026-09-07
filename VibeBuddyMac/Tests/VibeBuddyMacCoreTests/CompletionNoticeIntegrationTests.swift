import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

struct CompletionNoticeIntegrationTests {
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
