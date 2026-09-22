import Foundation
import Testing
@testable import VibeBuddyKit

/// The routing decision behind the Watch's notification-centre delegate: which
/// tap opens, which acts, and which does nothing — without a notification.
struct WatchNotificationResponseRouteTests {
    private func resolve(_ action: NotificationActionID?, dismiss: Bool = false,
                         session: String? = "s-build", approval: String? = "ap-1",
                         text: String? = nil) -> WatchNotificationResponseRoute {
        WatchNotificationResponseRoute.resolve(action: action, isDismiss: dismiss,
                                               sessionID: session, approvalID: approval, userText: text)
    }

    @Test func theDefaultTapOpensTheSession() {
        #expect(resolve(nil) == .open(sessionID: "s-build"))
        #expect(resolve(nil).isAction == false)
    }

    @Test func approveAndDenyBindToTheApprovalTheyCameWith() {
        #expect(resolve(.approve) == .decide(sessionID: "s-build", approvalID: "ap-1", choice: .allow))
        #expect(resolve(.deny) == .decide(sessionID: "s-build", approvalID: "ap-1", choice: .deny))
        #expect(resolve(.approve).isAction)
    }

    @Test func aDecisionWithoutAnApprovalIdOnlyOpens() {
        #expect(resolve(.approve, approval: nil) == .open(sessionID: "s-build"))
        #expect(resolve(.deny, approval: "  ") == .open(sessionID: "s-build"))
    }

    @Test func aReplyCarriesItsTrimmedTextOrOpens() {
        #expect(resolve(.answer, text: "  ship it \n") == .answer(sessionID: "s-build", text: "ship it"))
        #expect(resolve(.answer, text: "   ") == .open(sessionID: "s-build"))
        #expect(resolve(.answer, text: nil) == .open(sessionID: "s-build"))
    }

    @Test func dismissAndMissingSessionAreNotRequests() {
        #expect(resolve(.approve, dismiss: true) == .ignore)
        #expect(resolve(nil, session: nil) == .ignore)
        #expect(resolve(.approve, session: "") == .ignore)
        #expect(resolve(nil, session: nil).sessionID == nil)
    }

    @Test func anOutcomeTapsOnceForAcceptedTwiceForAnythingElseAndNotWhileSending() {
        #expect(WatchHaptics.actionOutcome(.sending).isEmpty)
        #expect(WatchHaptics.actionOutcome(.awaitingResolution) == [.short])
        #expect(WatchHaptics.actionOutcome(.failed) == [.long, .long])
        #expect(WatchHaptics.actionOutcome(.unknown) == [.long, .long])
        #expect(WatchHaptics.actionOutcome(.refused) == [.long, .long])
    }
}

/// When a state that does not hold the tapped request is allowed to end the
/// hold — the rule that decides whether a banner Approve reaches the Mac or is
/// abandoned with "this is no longer waiting on you".
struct WatchBannerActionPatienceTests {
    private let route = WatchNotificationResponseRoute.decide(sessionID: "s-build",
                                                              approvalID: "ap-1", choice: .allow)

    @Test func theSameRevisionComingBackIsNotEvidenceTheRequestIsGone() {
        // The R6/R8 shape: the approval is newer than anything the wrist holds,
        // and activation re-delivers the pre-tap context moments after launch.
        // `WatchStateInbox.accept` takes an equal revision back, so this is a
        // real install — and it must not end the hold.
        var held = WatchBannerAction(route: route, baselineRevision: 12)
        held.noteInstalled(revision: 12)
        #expect(held.provesRequestGone(currentRevision: 12) == false)
    }

    @Test func aStrictlyNewerRevisionWithoutTheRequestEndsTheHold() {
        var held = WatchBannerAction(route: route, baselineRevision: 12)
        held.noteInstalled(revision: 12)
        #expect(held.provesRequestGone(currentRevision: 13))
    }

    @Test func theFirstStateOfAColdHoldIsABaselineAndProvesNothing() {
        // Nothing usable on disk: the first payload to arrive is the mark, not
        // an answer about an approval the wrist has never seen.
        var held = WatchBannerAction(route: route)
        #expect(held.baselineRevision == nil)
        #expect(held.provesRequestGone(currentRevision: 40) == false)
        held.noteInstalled(revision: 40)
        #expect(held.baselineRevision == 40)
        #expect(held.provesRequestGone(currentRevision: 40) == false)
        #expect(held.provesRequestGone(currentRevision: 41))
    }

    @Test func theBaselineNeverMoves() {
        var held = WatchBannerAction(route: route, baselineRevision: 7)
        held.noteInstalled(revision: 8)
        held.noteInstalled(revision: 9)
        #expect(held.baselineRevision == 7)
        #expect(held.provesRequestGone(currentRevision: 8))
    }

    @Test func runningOutOfPatienceIsNotProofTheRequestEnded() {
        // The wrist gave up waiting; that is not the same as learning the
        // request left, and the card must not claim it was. The store picks the
        // honest sentence — this only refuses to hand it the wrong one.
        let held = WatchBannerAction(route: route, baselineRevision: 12)
        #expect(held.provesRequestGone(currentRevision: 12) == false)
        #expect(held.provesRequestGone(currentRevision: nil) == false)
    }
}
