import Foundation
import Testing
@testable import VibeBuddyKit

@MainActor
struct WatchNotificationRouterTests {
    @Test func coldNotificationDoesNotPresentDuringStoreCreation() {
        let router = WatchNotificationRouter()
        var opened: [String] = []
        router.open(sessionID: "completed-task")
        router.attach { opened.append($0.sessionID ?? "") }
        #expect(opened.isEmpty)
        router.setWindowActive(true)
        #expect(opened == ["completed-task"])
        router.setWindowActive(false)
        router.setWindowActive(true)
        #expect(opened == ["completed-task"])
    }

    @Test func backgroundTapWaitsForWindowAndLatestTapWins() {
        let router = WatchNotificationRouter()
        var opened: [String] = []
        router.attach { opened.append($0.sessionID ?? "") }
        router.setWindowActive(true)
        router.open(sessionID: "first")
        router.setWindowActive(false)
        router.open(sessionID: "older")
        router.open(sessionID: "latest")
        #expect(opened == ["first"])
        router.setWindowActive(true)
        #expect(opened == ["first", "latest"])
    }

    @Test func activeWindowBeforeStoreStillRetainsTarget() {
        let router = WatchNotificationRouter()
        var opened: [String] = []
        router.setWindowActive(true)
        router.open(sessionID: "target")
        router.open(sessionID: "")
        router.attach { opened.append($0.sessionID ?? "") }
        #expect(opened == ["target"])
    }

    @Test func liveActivityURLWaitsThenOpensExactSession() {
        let router = WatchNotificationRouter()
        var opened: [String] = []
        router.attach { opened.append($0.sessionID ?? "") }
        let url = VibeBuddyDeepLink.sessionURL(id: "codex/task#37")
        #expect(router.openActivityURL(url))
        #expect(opened.isEmpty)
        #expect(!router.openActivityURL(URL(string: "https://example.com")!))
        router.setWindowActive(true)
        #expect(opened == ["codex/task#37"])
    }

    @Test func aBannerDecisionTravelsWholeAndIgnoreDeliversNothing() {
        let router = WatchNotificationRouter()
        var routes: [WatchNotificationResponseRoute] = []
        router.attach { routes.append($0) }
        router.route(.ignore)
        router.setWindowActive(true)
        #expect(routes.isEmpty)
        router.route(.decide(sessionID: "s1", approvalID: "ap-1", choice: .allow))
        #expect(routes == [.decide(sessionID: "s1", approvalID: "ap-1", choice: .allow)])
    }
}
