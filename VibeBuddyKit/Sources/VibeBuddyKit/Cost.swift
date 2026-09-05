import Foundation

/// Rough cost estimation. The transcript only exposes a *combined* (input+output)
/// token count, so we use a single blended USD-per-million-tokens rate per model
/// family. Estimates only — clearly labelled as such in the UI.
public enum Pricing {
    public static func blendedRatePerMTok(_ model: String?) -> Double {
        let m = (model ?? "").lowercased()
        if m.contains("opus") { return 30 }
        if m.contains("sonnet") { return 6 }
        if m.contains("haiku") { return 1.5 }
        if m.contains("gpt-5") || m.contains("codex") || m.contains("o3") || m.contains("o4") { return 10 }
        return 8   // unknown model
    }

    /// Estimated USD for a token count, or nil when there's nothing to price.
    public static func estimatedUSD(tokens: Int?, model: String?) -> Double? {
        guard let tokens, tokens > 0 else { return nil }
        return Double(tokens) / 1_000_000 * blendedRatePerMTok(model)
    }
}

/// Watches per-session cumulative spend and fires once when a session crosses the
/// user's budget, never re-firing while it stays over. Pure + unit-tested.
public final class BudgetMonitor {
    public struct Alert: Equatable, Sendable {
        public let session: AgentSession
        public let estimatedUSD: Double
    }

    private var alerted: Set<String> = []   // ids currently over (already alerted)

    public init() {}

    /// Sessions that *newly* crossed `budgetUSD` since the last call. A session
    /// that falls out of the over-budget set (e.g. ends and a new one reuses
    /// nothing) can alert again on a future crossing.
    public func newlyOverBudget(_ sessions: [AgentSession], budgetUSD: Double) -> [Alert] {
        guard budgetUSD > 0 else { alerted.removeAll(); return [] }
        var fresh: [Alert] = []
        var over: Set<String> = []
        for s in sessions {
            guard let cost = Pricing.estimatedUSD(tokens: s.spentTokens, model: s.model),
                  cost >= budgetUSD else { continue }
            over.insert(s.id)
            if !alerted.contains(s.id) { fresh.append(Alert(session: s, estimatedUSD: cost)) }
        }
        alerted = over
        return fresh
    }
}

public extension AgentSession {
    /// Cumulative cost in USD: the agent's own client-side figure when it
    /// reports one (Claude's status line `cost.total_cost_usd`), else the rough
    /// estimate from spent tokens and list price; nil when nothing to price.
    var estimatedCostUSD: Double? { costUSD ?? Pricing.estimatedUSD(tokens: spentTokens, model: model) }
}
