import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Exact-round unread restoration")
struct UnreadRoundTests {
    @Test func restoringUnreadDoesNotRestartRemindersOrClearNewRound() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = SessionStore()
        func event(_ name: String) -> Data {
            Data("{\"hook_event_name\":\"\(name)\",\"session_id\":\"unread-round\",\"cwd\":\"/tmp/unread-round\"}".utf8)
        }
        await store.ingest(event("UserPromptSubmit"), receivedAt: now)
        await store.ingest(event("Stop"), receivedAt: now.addingTimeInterval(1))
        let snapshot = await store.snapshot(now: now.addingTimeInterval(2))
        let session = try #require(snapshot.sessions.first)
        let source = try #require(snapshot.sourceID)
        let completion = try #require(session.completionID)
        let read = CompletionReadRequest(sourceID: source, sessionID: session.id, completionID: completion)
        #expect(await store.acknowledgeCompletion(read, now: now.addingTimeInterval(3)).outcome == .accepted)
        let unread = CompletionReadRequest(sourceID: source, sessionID: session.id, completionID: completion, markUnread: true)
        #expect(await store.acknowledgeCompletion(unread, now: now.addingTimeInterval(4)).outcome == .accepted)
        var restored = try #require(await store.snapshot(now: now.addingTimeInterval(5)).sessions.first)
        #expect(restored.hasUnreadCompletion)
        restored.attentionOverride = .followed
        var reminders = CompletionReminderSchedule()
        #expect(reminders.due([restored], now: now.addingTimeInterval(3600)).isEmpty)
        await store.ingest(event("UserPromptSubmit"), receivedAt: now.addingTimeInterval(6))
        await store.ingest(event("Stop"), receivedAt: now.addingTimeInterval(7))
        #expect(await store.acknowledgeCompletion(read, now: now.addingTimeInterval(8)).outcome == .staleCompletion)
        #expect(await store.snapshot(now: now.addingTimeInterval(9)).sessions.first?.hasUnreadCompletion == true)
    }
    @Test func toolFailureDoesNotBecomeTerminalFailure() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var reducer = SessionReducer()
        reducer.apply(HookEvent(kind: .postToolUse, sessionID: "recover", agent: .claudeCode,
                               toolError: true, timestamp: now))
        #expect(reducer.sessions["recover"]?.status == .working)
        reducer.apply(HookEvent(kind: .stop, sessionID: "recover", agent: .claudeCode,
                               message: "Recovered after an error", timestamp: now.addingTimeInterval(1), completionSucceeded: true))
        #expect(reducer.sessions["recover"]?.failed == false)
        reducer.apply(HookEvent(kind: .stop, sessionID: "terminal", agent: .claudeCode,
                               timestamp: now.addingTimeInterval(2), completionSucceeded: false))
        #expect(reducer.sessions["terminal"]?.presentationState == .error)
    }
}
