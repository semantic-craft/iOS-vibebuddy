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

    @Test("a ref that achieved nothing → unsupported")
    func unsupported() {
        #expect(JumpOutcome.decide(hasRef: true, focusedExactTarget: false, activatedApp: false) == .unsupported)
    }

    @Test("round-trips over the wire as its raw string")
    func codable() throws {
        for outcome in [JumpOutcome.focused, .activatedApp, .unsupported, .noTerminal] {
            let data = try JSONEncoder().encode(["outcome": outcome.rawValue])
            let back = try JSONDecoder().decode([String: String].self, from: data)
            #expect(back["outcome"].flatMap(JumpOutcome.init(rawValue:)) == outcome)
        }
    }
}
