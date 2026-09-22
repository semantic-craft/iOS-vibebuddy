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
    /// The allowance closest to running out — the one that decides whether the
    /// next turn goes through, and what a ring draws. Scoped windows are named
    /// subdivisions of the same allowance, never an independent pool, so they
    /// are left out; a short window is in, because a five-hour pool at 4% stops
    /// work as surely as a week at 4%.
    func tightest(now: Date = Date()) -> QuotaReading? { poolReadings(now: now).first }
}

/// One line on a strip: the provider it belongs to and the one pool it reads.
/// A provider running several pools over one period (Cursor) yields one row
/// each, so the spent pool cannot hide behind the comfortable one.
public struct QuotaStripRow: Identifiable, Sendable, Equatable {
    public let quota: ProviderQuota
    public let window: QuotaWindow
    /// Identity follows the pool, not its position: when two pools cross, the
    /// rows move instead of swapping their contents under the eye.
    public var id: String {
        [quota.provider.rawValue, window.label ?? "",
         window.durationMinutes.map(String.init) ?? "",
         window.resetsAt.map { String(Int($0.timeIntervalSinceReferenceDate)) } ?? ""]
            .joined(separator: "#")
    }

    public init(quota: ProviderQuota, window: QuotaWindow) {
        self.quota = quota
        self.window = window
    }
}

public extension Collection where Element == ProviderQuota {
    /// This agent's own allowance, when the agent has an account to read.
    func reading(for agent: AgentKind, now: Date = Date()) -> QuotaReading? {
        first { $0.provider.agentKind == agent }?.tightest(now: now)
    }

    /// The fleet's tightest reading — what an "All agents" tile wears, since
    /// that is the allowance about to stop the day's work.
    func tightestReading(now: Date = Date()) -> QuotaReading? {
        compactMap { $0.tightest(now: now) }.min { $0.remainingPercent < $1.remainingPercent }
    }

    /// The rows a small screen reads, lowest first, unreadable ones sunk to the
    /// bottom rather than jumping the queue, ties settled by provider name so
    /// the list never reshuffles under the eye.
    ///
    /// It is a flat list of **rows**, not of providers, and it sorts by the
    /// number each row itself shows. That is the whole point: a Cursor pool at
    /// 90% left must not ride above a Claude row at 40% just because Cursor's
    /// other pool is at 10%. A list whose order contradicts its own numbers is
    /// worse than an unsorted one.
    func stripRowsLowestFirst(preferring kind: QuotaWindowKind = .weekly,
                              now: Date = Date()) -> [QuotaStripRow] {
        flatMap { quota in quota.stripWindows(preferring: kind, now: now).map { QuotaStripRow(quota: quota, window: $0) } }
            .sorted { lhs, rhs in
                let l = lhs.window.currentRemainingPercent(now: now)
                let r = rhs.window.currentRemainingPercent(now: now)
                switch (l, r) {
                case let (l?, r?):
                    if l != r { return l < r }
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): break
                }
                let names = lhs.quota.provider.displayName.localizedStandardCompare(rhs.quota.provider.displayName)
                if names != .orderedSame { return names == .orderedAscending }
                return (lhs.window.label ?? "") < (rhs.window.label ?? "")
            }
    }
}
