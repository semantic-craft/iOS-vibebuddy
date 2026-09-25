import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("JumpOutcome — what a jump-to-terminal request resolved to")
struct JumpOutcomeTests {

    @Test("no terminal ref → noTerminal, whatever else is claimed")
    func noRef() {
        #expect(JumpOutcome.decide(hasRef: false, focusedExactTarget: false, activatedApp: false) == .noTerminal)
        #expect(JumpOutcome.decide(hasRef: false, focusedExactTarget: true, activatedApp: true) == .noTerminal)
    }

    @Test("the session's own pane/tab came forward → focused")
    func focused() {
        #expect(JumpOutcome.decide(hasRef: true, focusedExactTarget: true, activatedApp: true) == .focused)
        // Focus without activation still counts: a tmux pane can be selected in a
        // terminal whose app we could not raise.
        #expect(JumpOutcome.decide(hasRef: true, focusedExactTarget: true, activatedApp: false) == .focused)
    }

    @Test("only the host app could be raised → activatedApp, not focused")
    func activatedApp() {
        #expect(JumpOutcome.decide(hasRef: true, focusedExactTarget: false, activatedApp: true) == .activatedApp)
    }
}
