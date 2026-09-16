import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Codex late progress")
struct CodexLateProgressTests {
    @Test func newerProgressInTheSameNativeTurnContinuesWorking() async throws {
        let store = SessionStore(sourceID: "source")
        let now = Date()
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .hook, timestamp: now, turnID: "a", completionSucceeded: true))
        let completion = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        await store.ingest(.init(kind: .preToolUse, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now.addingTimeInterval(1), turnID: "a"))
        let session = try #require(await store.snapshot(now: now).sessions.first)
        #expect(session.status == .working)
        #expect(session.completionID == nil)
        #expect(await store.completionBody(sessionID: "s", completionID: completion).text == nil)
    }

    @Test func completedNativeTurnCannotReopenBeforeItsFinalBodyArrives() async throws {
        let store = SessionStore(sourceID: "source")
        let now = Date()
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .hook, timestamp: now, turnID: "a", completionSucceeded: true))
        let completion = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        for kind in [HookEvent.Kind.userPromptSubmit, .preToolUse, .postToolUse, .notification] {
            await store.ingest(.init(kind: kind, sessionID: "s", agent: .codex,
                observationSource: .rollout, timestamp: now.addingTimeInterval(-1),
                turnID: "a", turnStartedAt: now.addingTimeInterval(-2)))
            let session = try #require(await store.snapshot(now: now).sessions.first)
            #expect(session.status == .done)
            #expect(session.completionID == completion)
            #expect(session.hasUnreadCompletion)
            #expect(session.observations?.contains(where: { $0.source == .rollout }) == true)
        }
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now, turnID: "a",
            turnStartedAt: now.addingTimeInterval(-2), completionText: "Exact A", completionSucceeded: true))
        #expect(await store.snapshot(now: now).sessions.first?.completionID == completion)
        #expect(await store.completionBody(sessionID: "s", completionID: completion).text == "Exact A")
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now, turnID: "a", completionSucceeded: false))
        #expect(await store.completionBody(sessionID: "s", completionID: completion).text == nil)
    }

    @Test func terminalEvidenceSurvivesRestartButDoesNotSwallowNewProgress() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = dir.appendingPathComponent("journal.json")
        let store = SessionStore(sourceID: "source", journalURL: journal)
        let now = Date()
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .hook, timestamp: now, turnID: "a", completionText: "A", completionSucceeded: true))
        let completion = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        let restored = SessionStore(sourceID: "source", journalURL: journal)
        await restored.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now.addingTimeInterval(-1), turnID: "a"))
        #expect(await restored.snapshot(now: now).sessions.first?.completionID == completion)
        await restored.ingest(.init(kind: .preToolUse, sessionID: "s", agent: .codex,
            observationSource: .hook, timestamp: now.addingTimeInterval(1)))
        #expect(await restored.snapshot(now: now).sessions.first?.status == .working)
        await restored.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now.addingTimeInterval(2), turnID: "b"))
        await restored.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now.addingTimeInterval(2),
            turnID: "b", completionText: "B", completionSucceeded: true))
        let next = try #require(await restored.snapshot(now: now).sessions.first?.completionID)
        #expect(next != completion)
        #expect(await restored.completionBody(sessionID: "s", completionID: next).text == "B")
    }
}
