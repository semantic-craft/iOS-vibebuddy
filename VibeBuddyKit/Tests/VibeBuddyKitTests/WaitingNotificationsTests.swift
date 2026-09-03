import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("Waiting notifications")
struct WaitingNotificationsTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ status: SessionStatus) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: "vibebuddy",
                     status: status,
                     waitKind: status == .needsResponse ? .permission : nil,
                     statusSince: now, updatedAt: now)
    }

    private func alert(_ id: String, _ sound: NotificationSound) -> SoundAlert {
        SoundAlert(session: session(id, .needsResponse), sound: sound)
    }

    @Test("One cue has one name, whichever device posts it")
    func identifierIsStable() {
        #expect(alert("s1", .needsApproval).notificationID == "s1-needs_approval")
        #expect(NotificationIdentity.id(sessionID: "s1", sound: .needsApproval) == "s1-needs_approval")
    }

    @Test("Re-posting the same cue reuses the identifier instead of stacking")
    func repostsCollapse() {
        var ledger = WaitingNotificationLedger()
        ledger.record([alert("s1", .needsApproval)])
        ledger.record([alert("s1", .needsApproval)])
        #expect(ledger.outstanding == ["s1-needs_approval"])
    }

    @Test("A permission and the nudge that follows it stay separate things to say")
    func differentCuesAreDifferentNotifications() {
        var ledger = WaitingNotificationLedger()
        ledger.record([alert("s1", .needsApproval), alert("s1", .longWaitNudge)])
        #expect(ledger.outstanding == ["s1-needs_approval", "s1-long_wait_nudge"])
    }

    @Test("An identifier fits the APNs collapse-id limit even for a long session id")
    func identifierFitsTheCollapseIdLimit() {
        let long = String(repeating: "a", count: 200) + "-tail"
        let id = NotificationIdentity.id(sessionID: long, sound: .needsAnswer)
        #expect(id.utf8.count <= NotificationIdentity.maxLength)
        #expect(id.hasSuffix("-tail-needs_answer"))
    }

    @Test("A session answered elsewhere has its notification withdrawn")
    func resolvedWaitIsWithdrawn() {
        var ledger = WaitingNotificationLedger()
        ledger.record([alert("s1", .needsApproval)])

        #expect(ledger.withdrawals(for: [session("s1", .needsResponse)]).isEmpty)
        #expect(ledger.withdrawals(for: [session("s1", .working)]) == ["s1-needs_approval"])
        #expect(ledger.outstanding.isEmpty)
    }

    @Test("A session that vanished from the snapshot is withdrawn too")
    func vanishedSessionIsWithdrawn() {
        var ledger = WaitingNotificationLedger()
        ledger.record([alert("s1", .needsApproval), alert("s2", .needsAnswer)])

        #expect(ledger.withdrawals(for: [session("s2", .needsResponse)]) == ["s1-needs_approval"])
        #expect(ledger.outstanding == ["s2-needs_answer"])
    }

    @Test("Withdrawing happens once, not on every later snapshot")
    func withdrawalIsNotRepeated() {
        var ledger = WaitingNotificationLedger()
        ledger.record([alert("s1", .needsApproval)])
        _ = ledger.withdrawals(for: [session("s1", .done)])
        #expect(ledger.withdrawals(for: [session("s1", .done)]).isEmpty)
    }

    @Test("A completion is history and is never taken back")
    func completionsAreNotTracked() {
        var ledger = WaitingNotificationLedger()
        ledger.record([
            SoundAlert(session: session("s1", .done), sound: .agentDone),
            SoundAlert(session: session("s2", .done), sound: .agentStuck),
        ])
        #expect(ledger.outstanding.isEmpty)
        #expect(ledger.withdrawals(for: []).isEmpty)
    }

    @Test("Only waiting cues are withdrawable")
    func waitingCuesAreTheWithdrawableOnes() {
        for sound in NotificationSound.allCases {
            let waiting = [NotificationSound.needsAnswer, .needsApproval, .longWaitNudge].contains(sound)
            #expect(sound.isWaitingCue == waiting, "\(sound.rawValue)")
        }
    }
}
