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
    /// The share at which an allowance starts changing what you do next. The
    /// Watch tints its strip here, and surfaces with no room for a standing
    /// reading (its alert card, its task header) show one only below it.
    public static let lowRemainingPercent = 10

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

    /// Little enough left that it belongs beside the decision, not only on
    /// the allowance page.
    public var isLow: Bool { remainingPercent <= Self.lowRemainingPercent }
}

public extension ProviderQuota {
    /// The window closest to running out — the one that decides whether the
    /// next turn goes through. Scoped windows are named subdivisions of the
    /// same allowance, never an independent pool, so they are left out.
    var tightest: QuotaReading? { poolReadings.first }

    /// Every independent pool as its own reading, tightest first. A ring or a
    /// tile can only draw one of them; its tooltip and its VoiceOver value say
    /// all of them, so a Cursor mark showing 0% still admits that the other
    /// pool has room, and one showing 87% still admits the other is spent.
    var poolReadings: [QuotaReading] {
        independentWindows
            .compactMap { window in
                window.remainingPercent.map {
                    QuotaReading(remainingPercent: $0, label: window.label, resetsAt: window.resetsAt)
                }
            }
            .sorted { $0.remainingPercent < $1.remainingPercent }
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

    /// The allowances in the order a small screen reads them: lowest first,
    /// unreadable ones sunk to the bottom rather than jumping the queue, ties
    /// settled by name so the list never reshuffles under the eye.
    ///
    /// It sorts by the number each row *shows* — `displayWindow`, which prefers
    /// the weekly pool and otherwise reads the tightest independent pool. A
    /// list whose order contradicts its own numbers is worse than an unsorted
    /// one, so the two stay defined together: a provider drawn at 31% files
    /// above one drawn at 41%, and a provider whose pools each get a row
    /// (Cursor) is placed by the tightest of them.
    func displayedLowestFirst(preferring kind: QuotaWindowKind = .weekly,
                              now: Date = Date()) -> [ProviderQuota] {
        sorted { lhs, rhs in
            let l = lhs.displayWindow(preferring: kind).currentRemainingPercent(now: now)
            let r = rhs.displayWindow(preferring: kind).currentRemainingPercent(now: now)
            switch (l, r) {
            case let (l?, r?):
                if l != r { return l < r }
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): break
            }
            return lhs.provider.displayName.localizedStandardCompare(rhs.provider.displayName) == .orderedAscending
        }
    }
}
