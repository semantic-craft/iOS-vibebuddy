import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("JumpOutcome — what a jump-to-terminal request resolved to")
struct JumpOutcomeTests {

    @Test("no terminal ref → noTerminal")
    func noRef() {
        #expect(JumpOutcome.decide(hasRef: false, hasRunnableCommand: false) == .noTerminal)
        #expect(JumpOutcome.decide(hasRef: false, hasRunnableCommand: true) == .noTerminal)
    }

    @Test("a ref with a runnable focus command → focused")
    func focused() {
        #expect(JumpOutcome.decide(hasRef: true, hasRunnableCommand: true) == .focused)
    }

    @Test("a ref but no runnable command (unknown terminal) → unsupported")
    func unsupported() {
        #expect(JumpOutcome.decide(hasRef: true, hasRunnableCommand: false) == .unsupported)
    }

    @Test("round-trips over the wire as its raw string")
    func codable() throws {
        for outcome in [JumpOutcome.focused, .unsupported, .noTerminal] {
            let data = try JSONEncoder().encode(["outcome": outcome.rawValue])
            let back = try JSONDecoder().decode([String: String].self, from: data)
            #expect(back["outcome"].flatMap(JumpOutcome.init(rawValue:)) == outcome)
        }
    }
}
