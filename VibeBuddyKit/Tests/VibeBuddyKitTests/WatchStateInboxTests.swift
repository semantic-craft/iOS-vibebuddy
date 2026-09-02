import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("Watch state inbox")
struct WatchStateInboxTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(at offset: TimeInterval = 0, working: Int = 1) -> WatchDashboardState {
        let sessions = (0..<working).map {
            AgentSession(id: "s\($0)", agent: .claudeCode, project: "vibebuddy",
                         status: .working,
                         statusSince: now, updatedAt: now)
        }
        return WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions, serverTime: now),
            quotas: [], relay: .live, now: now.addingTimeInterval(offset))
    }

    @Test("A first launch with nothing stored is no-data, not an empty dashboard")
    func firstLaunchIsNoData() {
        var inbox = WatchStateInbox()
        #expect(inbox.state == nil)
        let accepted = inbox.accept(nil)
        #expect(accepted == false)
        #expect(inbox.state == nil)
    }

    @Test("A valid payload round-trips through the inbox")
    func validPayloadIsAccepted() throws {
        var inbox = WatchStateInbox()
        let sent = state()
        let data = try #require(WatchStateInbox.encode(sent))
        let accepted = inbox.accept(data)
        #expect(accepted)
        #expect(inbox.state == sent)
    }

    @Test("Corrupt data is rejected and the last good state stays on screen")
    func corruptPayloadKeepsTheLastGoodState() throws {
        var inbox = WatchStateInbox()
        let good = state()
        inbox.accept(try #require(WatchStateInbox.encode(good)))

        let garbage = inbox.accept(Data("not json".utf8))
        let empty = inbox.accept(Data())
        let partial = inbox.accept(Data(#"{"counts":{"needsResponse":1}}"#.utf8))
        #expect(garbage == false)
        #expect(empty == false)
        #expect(partial == false)
        #expect(inbox.state == good)
    }

    @Test("Corrupt data with nothing stored leaves the Watch in no-data")
    func corruptPayloadOnFirstLaunchIsNoData() {
        var inbox = WatchStateInbox()
        let accepted = inbox.accept(Data("💥".utf8))
        #expect(accepted == false)
        #expect(inbox.state == nil)
    }

    @Test("A late delivery cannot walk the Watch backwards")
    func staleDeliveryIsRejected() throws {
        var inbox = WatchStateInbox()
        let newer = state(at: 60, working: 2)
        let older = state(at: 0, working: 1)
        inbox.accept(try #require(WatchStateInbox.encode(newer)))

        let accepted = inbox.accept(try #require(WatchStateInbox.encode(older)))
        #expect(accepted == false)
        #expect(inbox.state == newer)
    }

    @Test("A payload with the same observation time still lands")
    func sameObservationTimeIsAccepted() throws {
        var inbox = WatchStateInbox()
        inbox.accept(try #require(WatchStateInbox.encode(state(working: 1))))
        let corrected = state(working: 3)
        let accepted = inbox.accept(try #require(WatchStateInbox.encode(corrected)))
        #expect(accepted)
        #expect(inbox.state?.counts.working == 3)
    }

    @Test("A restored state recalculates its age from the current clock")
    func restoredStateAgesAgainstTheCurrentClock() throws {
        var inbox = WatchStateInbox(state: nil)
        let stored = state()
        inbox.accept(try #require(WatchStateInbox.encode(stored)))
        let restored = try #require(inbox.state)

        #expect(restored.age(now: now) == 0)
        #expect(restored.age(now: now.addingTimeInterval(3_600)) == 3_600)
    }

    @Test("The relayed payload carries no daemon secrets or session collection")
    func relayedPayloadLeaksNothing() throws {
        let waiting = AgentSession(
            id: "leaky", agent: .claudeCode, project: "vibebuddy", branch: "main",
            model: "claude-opus-4-8", status: .needsResponse, waitKind: .permission,
            pendingApproval: PendingApproval(
                id: "ap", tool: "Edit", commandPreview: "src/app.ts", filePath: "src/app.ts",
                oldText: "before()", newText: "after()"),
            terminalRef: TerminalRef(termProgram: "iTerm.app", tty: "/dev/ttys004"),
            summary: "safe summary", tokens: 98_765,
            statusSince: now, updatedAt: now)
        let projected = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: [waiting], serverTime: now),
            quotas: [], relay: .live, now: now)
        let data = try #require(WatchStateInbox.encode(projected))
        let json = String(decoding: data, as: UTF8.self)

        for secret in ["10.0.0", "Bearer", "ttys004", "iTerm.app", "before()", "after()", "98765"] {
            #expect(!json.contains(secret), "relay payload leaked \(secret)")
        }
        // One alert summary, not the session collection.
        #expect(!json.contains("\"sessions\""))
        #expect(!json.contains("pendingApproval"))
    }
}
