import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Companion copy — the two summary lines never say the same count twice")
struct CompanionCopyTests {
    private func summary(idle: Int = 0, thinking: Int = 0, completeUnread: Int = 0,
                         requiresInput: Int = 0, error: Int = 0) -> TaskPresentationSummary {
        TaskPresentationSummary(idle: idle, thinking: thinking, completeUnread: completeUnread,
                                requiresInput: requiresInput, error: error)
    }

    @Test("something waiting: the mood line names the waiting count, so the rest line keeps working")
    func waitingKeepsWorking() {
        let s = summary(idle: 4, thinking: 3, completeUnread: 7, requiresInput: 2, error: 1)
        #expect(CompanionCopy.moodLine(s) == "3 things need you")
        #expect(CompanionCopy.restLine(s) == "3 working · 7 done · 4 idle")
    }

    @Test("voice replaces the mood line: working remains in the rest line")
    func voiceHeadlineKeepsWorking() {
        #expect(CompanionCopy.restLine(summary(thinking: 3), moodLineIsVisible: false) == "3 working")
        #expect(CompanionCopy.restLine(summary(idle: 2, thinking: 3, completeUnread: 1),
                                       moodLineIsVisible: false) == "3 working · 1 done · 2 idle")
        #expect(CompanionCopy.restLine(summary(thinking: 3, requiresInput: 1),
                                       moodLineIsVisible: false) == "3 working")
        #expect(CompanionCopy.restLine(summary(), moodLineIsVisible: false) == "")
    }

    /// The bug this suite exists for: `All quiet — 3 working · 3 working · 7 done`.
    /// Callers render the two lines together, so no count-noun may appear in both.
    @Test("across every small snapshot, no term appears in both lines")
    func noTermAppearsTwice() {
        for error in 0...1 {
            for requiresInput in 0...2 {
                for thinking in 0...2 {
                    for completeUnread in 0...2 {
                        for idle in 0...2 {
                            let s = summary(idle: idle, thinking: thinking,
                                            completeUnread: completeUnread,
                                            requiresInput: requiresInput, error: error)
                            let mood = CompanionCopy.moodLine(s)
                            let rest = CompanionCopy.restLine(s)
                            for term in ["working", "done", "idle"] where mood.contains(term) {
                                #expect(!rest.contains(term),
                                        "“\(mood)” and “\(rest)” both say \(term)")
                            }
                        }
                    }
                }
            }
        }
    }
    @Test func attentionCountsAreDisjoint() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failed = AgentSession(id: "failed", agent: .codex, project: "app", status: .done,
                                  failed: true, hasUnreadCompletion: true, statusSince: now, updatedAt: now)
        let unread = AgentSession(id: "unread", agent: .codex, project: "app", status: .done,
                                  hasUnreadCompletion: true, statusSince: now, updatedAt: now)
        let value = TaskPresentationSummary(currentIn: [failed, unread], now: now)
        #expect(value.needsYou == 1)
        #expect(value.completeUnread == 1)
        #expect(value.pendingCount == 2)
        #expect(CompanionCopy.attentionLine(value) == "Needs you 1 · Unread results 1")
    }
}
