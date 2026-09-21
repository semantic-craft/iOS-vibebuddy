import Foundation
import Testing
@testable import VibeBuddyKit

struct SetupChecklistTests {
    enum Step { case install, pair }

    @Test func firstUndoneStepIsCurrent() {
        let fresh = SetupChecklist([.init(Step.install, done: false), .init(.pair, done: false)])
        #expect(fresh.current == .install)
        #expect(fresh.doneCount == 0)
        #expect(fresh.position(of: .pair) == 2)

        let sent = SetupChecklist([.init(Step.install, done: true), .init(.pair, done: false)])
        #expect(sent.current == .pair)
        #expect(sent.doneCount == 1)
        #expect(!sent.isComplete)
    }

    @Test func doneStepsAfterAnUndoneOneDoNotHideIt() {
        // Order-agnostic: a user who paired before "sending" the Mac link
        // still gets step 1 highlighted, not a false "all done".
        let list = SetupChecklist([.init(Step.install, done: false), .init(.pair, done: true)])
        #expect(list.current == .install)
        #expect(list.doneCount == 1)
    }

    @Test func allDoneIsComplete() {
        let list = SetupChecklist([.init(Step.install, done: true), .init(.pair, done: true)])
        #expect(list.isComplete)
        #expect(list.current == nil)
        #expect(SetupChecklist<Step>([]).isComplete)
    }

    @Test func appStoreLinkIsStorefrontAgnostic() {
        let url = CompanionLinks.iPhoneAppStore
        #expect(url.host == "apps.apple.com")
        #expect(url.path == "/app/id6777469338")
        #expect(CompanionLinks.macDownload.host == "github.com")
    }
}
