import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

struct CursorPersistentSessionsTests {
    let id = "52cf2de1-01cb-4a88-a774-7743d1cac3af"
    var output: String {
        """
        1 persistent session:

        Task: Shell Command Sleep
          Status: Detached (running in background)
          Session: cursor-project-31ec65e8a6-1-f87233
          Chat ID: \(id)
          Workspace: /tmp/disposable-project
          Attach: agent persist attach cursor-project-31ec65e8a6-1-f87233

        """
    }

    @Test func nativeIdentityAndFormatMustBeComplete() {
        guard case .available(let sessions) = CursorPersistentSessions.parse(output) else {
            Issue.record("real CLI block rejected"); return
        }
        #expect(sessions.count == 1 && sessions[0].chatID == id && !sessions[0].attached)
        #expect(CursorPersistentSessions.parse("No Cursor-managed persistent sessions.\n") == .available([]))
        #expect(CursorPersistentSessions.parse(output.replacingOccurrences(of: id, with: "Shell Command Sleep")) == .unavailable)
        #expect(CursorPersistentSessions.parse(output.replacingOccurrences(of: "Chat ID:", with: "Chat:")) == .unavailable)
        #expect(CursorPersistentSessions.parse(output.replacingOccurrences(of: "1 persistent session:", with: "2 persistent sessions:")) == .unavailable)
    }

    @Test func transportDiscoveryNeverCreatesACompletionOrClaimsOwnership() async {
        let store = SessionStore()
        let now = Date()
        guard case .available(let sessions) = CursorPersistentSessions.parse(output) else { return }
        await store.registerCursorPersistentSessions(sessions, now: now)
        await store.registerCursorPersistentSessions(sessions, now: now.addingTimeInterval(30))
        let initial = await store.snapshot(now: now).sessions.first { $0.id == id }
        #expect(initial?.historyOnly == true)
        #expect(initial?.completionID == nil && initial?.cursorACPRecoverable != true)
        #expect(initial?.controlChannel == ControlChannel.none)
        #expect(initial.map { !SessionActionSupport.resolve(for: $0).isAvailable } == true)
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: id, agent: .cursor,
                                    cwd: "/tmp/disposable-project", timestamp: now))
        await store.registerCursorPersistentSessions(sessions, now: now.addingTimeInterval(60))
        let live = await store.snapshot(now: now).sessions.filter { $0.id == id }
        #expect(live.count == 1 && live[0].status == .working && live[0].historyOnly != true)
    }
    @Test func unavailableDiscoveryRemovesStaleRowsAndCanRecover() async {
        let store = SessionStore()
        let discovery = CursorPersistentSessions.parse(output)
        await store.applyCursorPersistentDiscovery(discovery)
        #expect(await store.snapshot(now: Date()).sessions.contains { $0.id == id })
        await store.applyCursorPersistentDiscovery(.unavailable)
        #expect(await store.snapshot(now: Date()).sessions.allSatisfy { $0.id != id })
        await store.applyCursorPersistentDiscovery(discovery)
        #expect(await store.snapshot(now: Date()).sessions.contains { $0.id == id })
    }

}
