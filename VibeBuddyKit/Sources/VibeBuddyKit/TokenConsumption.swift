import Foundation

/// Which calendar window a token-consumption summary covers.
public enum TokenConsumptionWindowKind: String, Codable, Sendable {
    case today
    case last7Days

    public var title: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "Last 7 days"
        }
    }
}

/// Non-overlapping token buckets, matching vibe-usage's Anthropic-style split:
/// cache reads and reasoning are stored separately from uncached input / output.
public struct TokenCountBreakdown: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var reasoningOutputTokens: Int
    /// Sum of per-entry list-price estimates; never a billed invoice.
    public var estimatedUSD: Double
    public var sessionCount: Int

    /// Tokens that drive spend (excludes cache reads).
    public var billedTokens: Int { inputTokens + outputTokens + reasoningOutputTokens }

    public var totalTokens: Int { billedTokens + cachedInputTokens }

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        estimatedUSD: Double = 0,
        sessionCount: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.estimatedUSD = estimatedUSD
        self.sessionCount = sessionCount
    }

    public var isEmpty: Bool { totalTokens == 0 && sessionCount == 0 }

    public static func + (lhs: Self, rhs: Self) -> Self {
        TokenCountBreakdown(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens,
            estimatedUSD: lhs.estimatedUSD + rhs.estimatedUSD,
            sessionCount: lhs.sessionCount + rhs.sessionCount)
    }
}

/// One slice of a consumption window (an agent, model, or project).
public struct TokenConsumptionRow: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var counts: TokenCountBreakdown
    public var id: String { key }

    public init(key: String, label: String, counts: TokenCountBreakdown) {
        self.key = key
        self.label = label
        self.counts = counts
    }
}

public struct TokenConsumptionWindow: Codable, Equatable, Sendable, Identifiable {
    public var kind: TokenConsumptionWindowKind
    public var counts: TokenCountBreakdown
    public var byAgent: [TokenConsumptionRow]
    public var byModel: [TokenConsumptionRow]
    public var byProject: [TokenConsumptionRow]
    public var id: TokenConsumptionWindowKind { kind }

    public init(
        kind: TokenConsumptionWindowKind,
        counts: TokenCountBreakdown,
        byAgent: [TokenConsumptionRow] = [],
        byModel: [TokenConsumptionRow] = [],
        byProject: [TokenConsumptionRow] = []
    ) {
        self.kind = kind
        self.counts = counts
        self.byAgent = byAgent
        self.byModel = byModel
        self.byProject = byProject
    }
}

/// Local token-consumption totals composed beside quota. Optional on the wire
/// so older phones ignore it. Never carries prompts or session progress.
public struct TokenConsumptionSnapshot: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var windows: [TokenConsumptionWindow]
    public var warnings: [String]?

    public init(observedAt: Date, windows: [TokenConsumptionWindow], warnings: [String]? = nil) {
        self.observedAt = observedAt
        self.windows = windows
        self.warnings = warnings
    }

    public func window(_ kind: TokenConsumptionWindowKind) -> TokenConsumptionWindow? {
        windows.first { $0.kind == kind }
    }

    /// Compact display for token counts (1.2M, 45K).
    public static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            let value = Double(n) / 1_000_000
            return String(format: value >= 10 ? "%.0fM" : "%.1fM", value)
        }
        if n >= 1_000 { return "\(n / 1_000)K" }
        return "\(n)"
    }

    public static func formatUSD(_ usd: Double) -> String {
        String(format: "≈ $%.2f", usd)
    }

    /// Sample totals for Demo mode. Not a reading of anyone's logs.
    public static func demo(now: Date = Date()) -> TokenConsumptionSnapshot {
        let today = TokenCountBreakdown(
            inputTokens: 420_000, outputTokens: 86_000,
            cachedInputTokens: 1_800_000, reasoningOutputTokens: 24_000,
            estimatedUSD: 18.40, sessionCount: 4)
        let week = TokenCountBreakdown(
            inputTokens: 2_400_000, outputTokens: 410_000,
            cachedInputTokens: 9_200_000, reasoningOutputTokens: 95_000,
            estimatedUSD: 96.10, sessionCount: 19)
        return TokenConsumptionSnapshot(observedAt: now, windows: [
            TokenConsumptionWindow(
                kind: .today, counts: today,
                byAgent: [
                    TokenConsumptionRow(key: "claudeCode", label: AgentKind.claudeCode.displayName,
                                        counts: TokenCountBreakdown(inputTokens: 300_000, outputTokens: 60_000,
                                                                    cachedInputTokens: 1_200_000, reasoningOutputTokens: 0,
                                                                    estimatedUSD: 14.20, sessionCount: 2)),
                    TokenConsumptionRow(key: "codex", label: AgentKind.codex.displayName,
                                        counts: TokenCountBreakdown(inputTokens: 120_000, outputTokens: 26_000,
                                                                    cachedInputTokens: 600_000, reasoningOutputTokens: 24_000,
                                                                    estimatedUSD: 4.20, sessionCount: 2)),
                ],
                byModel: [
                    TokenConsumptionRow(key: "claude-opus-4-8", label: "claude-opus-4-8",
                                        counts: TokenCountBreakdown(inputTokens: 300_000, outputTokens: 60_000,
                                                                    cachedInputTokens: 1_200_000, estimatedUSD: 14.20, sessionCount: 2)),
                    TokenConsumptionRow(key: "gpt-5-codex", label: "gpt-5-codex",
                                        counts: TokenCountBreakdown(inputTokens: 120_000, outputTokens: 26_000,
                                                                    cachedInputTokens: 600_000, reasoningOutputTokens: 24_000,
                                                                    estimatedUSD: 4.20, sessionCount: 2)),
                ],
                byProject: [
                    TokenConsumptionRow(key: "ios-vibebuddy", label: "ios-vibebuddy",
                                        counts: TokenCountBreakdown(inputTokens: 210_000, outputTokens: 40_000,
                                                                    cachedInputTokens: 900_000, estimatedUSD: 9.10, sessionCount: 2)),
                    TokenConsumptionRow(key: "todo-app", label: "todo-app",
                                        counts: TokenCountBreakdown(inputTokens: 210_000, outputTokens: 46_000,
                                                                    cachedInputTokens: 900_000, reasoningOutputTokens: 24_000,
                                                                    estimatedUSD: 9.30, sessionCount: 2)),
                ]),
            TokenConsumptionWindow(
                kind: .last7Days, counts: week,
                byAgent: [
                    TokenConsumptionRow(key: "claudeCode", label: AgentKind.claudeCode.displayName,
                                        counts: TokenCountBreakdown(inputTokens: 1_600_000, outputTokens: 280_000,
                                                                    cachedInputTokens: 6_000_000, estimatedUSD: 72.00, sessionCount: 11)),
                    TokenConsumptionRow(key: "codex", label: AgentKind.codex.displayName,
                                        counts: TokenCountBreakdown(inputTokens: 800_000, outputTokens: 130_000,
                                                                    cachedInputTokens: 3_200_000, reasoningOutputTokens: 95_000,
                                                                    estimatedUSD: 24.10, sessionCount: 8)),
                ],
                byModel: [
                    TokenConsumptionRow(key: "claude-opus-4-8", label: "claude-opus-4-8",
                                        counts: TokenCountBreakdown(inputTokens: 1_200_000, outputTokens: 210_000,
                                                                    cachedInputTokens: 4_400_000, estimatedUSD: 58.00, sessionCount: 7)),
                    TokenConsumptionRow(key: "claude-sonnet-4-5", label: "claude-sonnet-4-5",
                                        counts: TokenCountBreakdown(inputTokens: 400_000, outputTokens: 70_000,
                                                                    cachedInputTokens: 1_600_000, estimatedUSD: 14.00, sessionCount: 4)),
                    TokenConsumptionRow(key: "gpt-5-codex", label: "gpt-5-codex",
                                        counts: TokenCountBreakdown(inputTokens: 800_000, outputTokens: 130_000,
                                                                    cachedInputTokens: 3_200_000, reasoningOutputTokens: 95_000,
                                                                    estimatedUSD: 24.10, sessionCount: 8)),
                ],
                byProject: [
                    TokenConsumptionRow(key: "ios-vibebuddy", label: "ios-vibebuddy",
                                        counts: TokenCountBreakdown(inputTokens: 1_100_000, outputTokens: 190_000,
                                                                    cachedInputTokens: 4_000_000, reasoningOutputTokens: 40_000,
                                                                    estimatedUSD: 44.00, sessionCount: 9)),
                    TokenConsumptionRow(key: "todo-app", label: "todo-app",
                                        counts: TokenCountBreakdown(inputTokens: 800_000, outputTokens: 140_000,
                                                                    cachedInputTokens: 3_100_000, reasoningOutputTokens: 30_000,
                                                                    estimatedUSD: 32.00, sessionCount: 6)),
                    TokenConsumptionRow(key: "search-indexer", label: "search-indexer",
                                        counts: TokenCountBreakdown(inputTokens: 500_000, outputTokens: 80_000,
                                                                    cachedInputTokens: 2_100_000, reasoningOutputTokens: 25_000,
                                                                    estimatedUSD: 20.10, sessionCount: 4)),
                ]),
        ])
    }
}
