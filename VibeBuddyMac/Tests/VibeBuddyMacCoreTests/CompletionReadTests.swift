import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

func completionReadRequest(_ store: SessionStore, sessionID: String) async throws -> CompletionReadRequest {
    let snapshot = await store.snapshot(now: Date())
    return CompletionReadRequest(sourceID: try #require(snapshot.sourceID), sessionID: sessionID,
        completionID: try #require(snapshot.sessions.first(where: { $0.id == sessionID })?.completionID))
}

struct CompletionReadTests {
    @Test("Exact completion read survives restart, duplicate stops, and delayed reads against a later turn")
    func roundIdentityAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.json")
        let now = Date()
        func event(_ kind: HookEvent.Kind, _ offset: TimeInterval) -> HookEvent {
            HookEvent(kind: kind, sessionID: "a", agent: .claudeCode,
                      cwd: "/x/project", timestamp: now.addingTimeInterval(offset))
        }
        let first = SessionStore(sourceID: "mac-a", journalURL: url, now: now)
        await first.ingest(event(.userPromptSubmit, 0))
        await first.ingest(event(.stop, 1))
        let read = try await completionReadRequest(first, sessionID: "a")
        let restored = SessionStore(sourceID: "mac-a", journalURL: url, now: now.addingTimeInterval(2))
        #expect(try await completionReadRequest(restored, sessionID: "a") == read)
        #expect(await restored.acknowledgeCompletion(read, now: now.addingTimeInterval(3)).outcome == .accepted)
        let again = SessionStore(sourceID: "mac-a", journalURL: url, now: now.addingTimeInterval(4))
        #expect(await again.acknowledgeCompletion(read).outcome == .alreadyAcknowledged)
        await again.ingest(event(.stop, 5))
        #expect(await again.snapshot(now: now).sessions.first?.hasUnreadCompletion == false)
        #expect(try await completionReadRequest(again, sessionID: "a") == read)
        await again.ingest(event(.userPromptSubmit, 6))
        #expect(await again.acknowledgeCompletion(read).outcome == .staleCompletion)
        await again.ingest(event(.stop, 7))
        let next = try await completionReadRequest(again, sessionID: "a")
        #expect(next.completionID != read.completionID)
        #expect(await again.acknowledgeCompletion(read).outcome == .staleCompletion)
        let wrongSource = CompletionReadRequest(sourceID: "mac-b", sessionID: "a", completionID: next.completionID)
        #expect(await again.acknowledgeCompletion(wrongSource).outcome == .sourceMismatch)
        #expect(await again.snapshot(now: now).sessions.first?.hasUnreadCompletion == true)
    }

    @Test("Diagnostic pruning and clearing preserve current completion identity")
    func completionOutlivesDiagnostics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.json")
        let now = Date()
        var journal = LifecycleJournal(url: url, capacity: 1, retention: 1, now: now)
        journal.append(LifecycleJournalEntry(sessionID: "done", agent: .claudeCode,
            event: "stop", source: .hook, timestamp: now, status: .done, waitKind: nil,
            completionID: "round-a", hasUnreadCompletion: true, statusSince: now), now: now)
        journal.append(LifecycleJournalEntry(sessionID: "other", agent: .claudeCode,
            event: "start", source: .hook, timestamp: now.addingTimeInterval(2),
            status: .working, waitKind: nil), now: now.addingTimeInterval(2))
        #expect(journal.recent(limit: 10).count == 1)
        let cleared = journal.clear()
        #expect(cleared)
        let restored = LifecycleJournal(url: url, now: now.addingTimeInterval(10_000))
        #expect(restored.recent(limit: 10).isEmpty)
        #expect(restored.restorableSessions(now: now.addingTimeInterval(10_000), meaningfulFor: 10)
            .first?.completionID == "round-a")
        journal.append(LifecycleJournalEntry(sessionID: "done", agent: .claudeCode,
            event: "newTurn", source: .hook, timestamp: now.addingTimeInterval(10_000),
            status: .working, waitKind: nil), now: now.addingTimeInterval(10_000))
        let afterNewTurn = LifecycleJournal(url: url, now: now.addingTimeInterval(10_001))
        #expect(afterNewTurn.restorableSessions(now: now.addingTimeInterval(10_001), meaningfulFor: 10)
            .allSatisfy { $0.completionID == nil })
    }

    @Test("A failed durable read write cannot report acceptance or clear unread")
    func persistenceFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.json")
        let now = Date()
        let store = SessionStore(sourceID: "mac-a", journalURL: url, now: now)
        await store.ingest(HookEvent(kind: .stop, sessionID: "a", agent: .claudeCode,
                                     cwd: "/x/project", timestamp: now))
        let read = try await completionReadRequest(store, sessionID: "a")
        // An existing directory cannot be atomically replaced by a journal file.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(await store.acknowledgeCompletion(read).outcome == .failed)
        #expect(await store.snapshot(now: now).sessions.first?.hasUnreadCompletion == true)
    }
}
