import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("Cost — pricing & budget monitor")
struct CostTests {

    private func session(_ id: String, spent: Int?, model: String? = "claude-opus-4-8") -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, model: model,
                     status: .working, spentTokens: spent,
                     statusSince: Date(timeIntervalSince1970: 0),
                     updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("blended rate varies by model family")
    func rates() {
        #expect(Pricing.blendedRatePerMTok("claude-opus-4-8") > Pricing.blendedRatePerMTok("claude-sonnet-4-6"))
        #expect(Pricing.blendedRatePerMTok("claude-sonnet-4-6") > Pricing.blendedRatePerMTok("claude-haiku-4-5"))
    }

    @Test("cost scales with tokens; zero/nil prices to nil")
    func cost() {
        let oneM = Pricing.estimatedUSD(tokens: 1_000_000, model: "claude-opus-4-8")
        #expect(oneM == 30)
        #expect(Pricing.estimatedUSD(tokens: 0, model: "claude-opus-4-8") == nil)
        #expect(Pricing.estimatedUSD(tokens: nil, model: "claude-opus-4-8") == nil)
    }

    @Test("budget fires once when a session crosses, not again while it stays over")
    func firesOnce() {
        let m = BudgetMonitor()
        // $5 budget; opus at $30/Mtok → 200k tokens = $6 > $5.
        let s = session("a", spent: 200_000)
        #expect(m.newlyOverBudget([s], budgetUSD: 5).map(\.session.id) == ["a"])
        #expect(m.newlyOverBudget([s], budgetUSD: 5).isEmpty)   // still over → no re-fire
    }

    @Test("under budget never fires")
    func underBudget() {
        let m = BudgetMonitor()
        let s = session("a", spent: 50_000)   // $1.5 < $5
        #expect(m.newlyOverBudget([s], budgetUSD: 5).isEmpty)
    }

    @Test("a session that leaves the set can fire again on a later crossing")
    func refireAfterLeaving() {
        let m = BudgetMonitor()
        let over = session("a", spent: 200_000)
        #expect(m.newlyOverBudget([over], budgetUSD: 5).count == 1)
        #expect(m.newlyOverBudget([], budgetUSD: 5).isEmpty)        // gone
        #expect(m.newlyOverBudget([over], budgetUSD: 5).count == 1) // back → fires again
    }

    @Test("a zero budget disables alerts")
    func disabled() {
        let m = BudgetMonitor()
        #expect(m.newlyOverBudget([session("a", spent: 999_999)], budgetUSD: 0).isEmpty)
    }
}
