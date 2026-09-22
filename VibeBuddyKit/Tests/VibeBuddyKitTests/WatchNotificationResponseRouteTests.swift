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
