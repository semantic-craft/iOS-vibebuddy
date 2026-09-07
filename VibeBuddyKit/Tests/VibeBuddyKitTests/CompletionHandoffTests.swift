import Foundation
import Testing
@testable import VibeBuddyKit

struct CompletionHandoffTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func session() -> AgentSession {
        var s = AgentSession(id: "task", agent: .codex, project: "Demo", status: .done,
                             hasUnreadCompletion: true, attention: .followed,
                             statusSince: now, updatedAt: now)
        s.completionID = "round-1"
        s.summary = "Old activity"
        s.completionNotice = .init(id: "mac/task/round-1", deadline: now.addingTimeInterval(12),
                                  state: .summary, text: "Fixed. Device verification remains pending.")
        return s
    }

    @Test func oneResultReachesPhoneVoiceAndWatchWithoutDroppingQualification() {
        let s = session().validatingCompletionNotice(sourceID: "mac")
        #expect(s.displaySummary == "Fixed. Device verification remains pending.")
        #expect(VoicePrompt.systemPrompt(sessions: [s]).contains("Device verification remains pending."))
        let watch = WatchDashboardProjection.make(snapshot: Snapshot(sessions: [s], serverTime: now, sourceID: "mac"),
                                                  quotas: [], relay: .live, now: now)
        #expect(watch.followedTasks.first?.summary == s.displaySummary)
        var otherSource = s.validatingCompletionNotice(sourceID: "another-mac")
        #expect(otherSource.displaySummary == "Old activity")
        otherSource = s; otherSource.completionID = "round-2"
        #expect(otherSource.displaySummary == "Old activity")
        otherSource = s; otherSource.status = .working
        #expect(otherSource.displaySummary == "Old activity")
    }
    @Test func completionNotificationRejectsAnotherRoundAndSource() throws {
        let s = session()
        let id = SoundAlert(session: s, sound: .agentDone).notificationID
        let url = VibeBuddyDeepLink.sessionURL(id: s.id, completionNotificationID: id)
        #expect(VibeBuddyDeepLink.completionNotificationID(from: url) == id)
        #expect(s.matchesCompletionNotification(id, sourceID: "mac"))
        #expect(!s.matchesCompletionNotification(id, sourceID: "another-mac"))
        var newer = s; newer.completionID = "round-2"
        #expect(!newer.matchesCompletionNotification(id, sourceID: "mac"))
        #expect(!s.matchesCompletionNotification("legacy-task-agent_done", sourceID: "mac"))
    }

    @Test func watchDetailKeepsTheWholeQualificationButWidgetRemainsCompact() throws {
        var s = session()
        s.completionNotice?.text = String(repeating: "界面更新完成。", count: 16) + "尚未完成手机验收。"
        let state = WatchDashboardProjection.make(snapshot: Snapshot(sessions: [s], serverTime: now, sourceID: "mac"),
                                                  quotas: [], relay: .live, now: now)
        #expect(state.followedTasks.first?.detailSummary?.hasSuffix("尚未完成手机验收。") == true)
        #expect(WatchComplicationSnapshot(state: state).tasks.first?.detailSummary == nil)
        #expect((WatchComplicationSnapshot(state: state).tasks.first?.summary?.count ?? 0) <= 100)
    }

    @Test func ordinaryNoticeCanOpenCurrentDetailWithoutProvingARead() {
        var s = session(); s.completionNotice = nil
        let id = NotificationIdentity.id(sessionID: s.id, sound: .agentDone)
        #expect(s.isUnboundCompletionNotification(id))
        #expect(!s.matchesCompletionNotification(id, sourceID: "mac"))
        s.completionID = "round-2"
        #expect(s.isUnboundCompletionNotification(id))
        #expect(!s.matchesCompletionNotification(id, sourceID: "mac"))
    }

    @Test func nonSummaryDecisionsAndMalformedTextNeverBecomeAResult() {
        for state in [CompletionNotice.State.pending, .plain, .cancelled] {
            var s = session(); s.completionNotice?.state = state
            #expect(s.completionSummary == nil)
            #expect(s.displaySummary == "Old activity")
            #expect(WatchFollowedTask(s).detailSummary == nil)
        }
        var s = session(); s.completionNotice?.text = String(repeating: "x", count: 181)
        s.summary = "cat /private/original-result"
        #expect(WatchFollowedTask(s).detailSummary == nil)
        #expect(WatchFollowedTask(s).summary == nil)
    }

}
