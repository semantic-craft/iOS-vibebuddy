import Foundation

/// Who is working, and how much of your attention each of them has earned.
/// The Mac's agent rail and the phone's agent strip are the same reading at
/// two sizes (ADR-0031), so the arithmetic lives here rather than twice.
/// Pure projection: it never mutates the snapshot and never picks a selection.
public enum AgentRoster {
    /// What one entry has to say where there is no room for words: how many
    /// sessions it owns and how they are split, so a tile can carry a count
    /// and an attention dot without re-reading the snapshot itself.
    public struct Tally: Sendable, Equatable {
        public let total: Int
        public let needsYou: Int
        public let working: Int
        public let unread: Int

        public init(total: Int = 0, needsYou: Int = 0, working: Int = 0, unread: Int = 0) {
            self.total = total
            self.needsYou = needsYou
            self.working = working
            self.unread = unread
        }
    }

    public struct Item: Identifiable, Sendable, Equatable {
        /// `nil` is the "All agents" entry, which always leads.
        public let agent: AgentKind?
        public let tally: Tally
        public var id: String { agent?.rawValue ?? "all" }

        public init(agent: AgentKind?, tally: Tally) {
            self.agent = agent
            self.tally = tally
        }
    }

    /// One entry per agent reporting in the current window, "All agents"
    /// first. `keeping` is the surface's own selection: an agent whose last
    /// session has just aged out stays listed, so the tiles never shift under
    /// the pointer and the page being read does not empty itself.
    public static func items(_ sessions: [AgentSession], keeping: AgentKind? = nil,
                             now: Date = Date()) -> [Item] {
        let current = SessionCurrency.current(sessions, now: now)
        var present = SessionFilter.presentAgents(current)
        if let keeping, !present.contains(keeping) { present.append(keeping) }
        return [Item(agent: nil, tally: tally(current))]
            + present.map { agent in Item(agent: agent, tally: tally(current.filter { $0.agent == agent })) }
    }

    /// A session needs you when it is blocked *or* broken — the same pairing
    /// the menu panel, the phone and the Watch use.
    public static func tally(_ sessions: [AgentSession]) -> Tally {
        let summary = TaskPresentationSummary(sessions: sessions)
        return Tally(total: sessions.count,
                     needsYou: summary.requiresInput + summary.error,
                     working: summary.thinking,
                     unread: summary.completeUnread)
    }
}

/// One provider's allowance boiled down to the single number a tile can wear.
public struct QuotaReading: Sendable, Equatable {
    /// Percent **remaining**, the one quota vocabulary (`ProviderQuota`).
    public let remainingPercent: Int
    public let label: String?
    public let resetsAt: Date?

    public init(remainingPercent: Int, label: String? = nil, resetsAt: Date? = nil) {
        self.remainingPercent = remainingPercent
        self.label = label
        self.resetsAt = resetsAt
    }

    /// What has been spent, for the bars and rings that fill as you work.
    public var usedPercent: Int { max(0, min(100, 100 - remainingPercent)) }
}

public extension ProviderQuota {
    /// The window closest to running out — the one that decides whether the
    /// next turn goes through. Scoped windows are named subdivisions of the
    /// same allowance, never an independent pool, so they are left out.
    var tightest: QuotaReading? {
        var readings: [QuotaReading] = []
        if let weekly = weeklyRemainingPercent {
            readings.append(QuotaReading(remainingPercent: weekly, label: weeklyLabel, resetsAt: weeklyResetsAt))
        }
        if let short = shortWindowRemainingPercent {
            readings.append(QuotaReading(remainingPercent: short, label: shortWindowLabel, resetsAt: shortWindowResetsAt))
        }
        for window in otherWindows ?? [] {
            guard let remaining = window.remainingPercent else { continue }
            readings.append(QuotaReading(remainingPercent: remaining, label: window.label, resetsAt: window.resetsAt))
        }
        return readings.min { $0.remainingPercent < $1.remainingPercent }
    }
}

public extension Collection where Element == ProviderQuota {
    /// This agent's own allowance, when the agent has an account to read.
    func reading(for agent: AgentKind) -> QuotaReading? {
        first { $0.provider.agentKind == agent }?.tightest
    }

    /// The fleet's tightest reading — what an "All agents" tile wears, since
    /// that is the allowance about to stop the day's work.
    var tightestReading: QuotaReading? {
        compactMap(\.tightest).min { $0.remainingPercent < $1.remainingPercent }
    }
}
