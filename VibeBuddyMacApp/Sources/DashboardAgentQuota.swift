import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// One agent's allowance, as the rail's ring and the column head read it: the
/// window closest to running out, because that is the one that decides whether
/// the next turn goes through. It is the same arithmetic the Usage page shows
/// in full — here it sits next to the agent it belongs to, so "who should take
/// this next" is one reading rather than two surfaces (the sidebar's old
/// account-quota plinth is gone; ADR-0017 §6 keeps the detail on Usage).
@MainActor
struct AgentQuotaReading {
    let provider: AccountUsageProvider
    let usedPercent: Int
    let windowName: String
    let resetsAt: Date?
    let isStale: Bool
    /// When the reading was taken; what "stale" is measured from.
    let observedAt: Date?
    /// No status-line forwarder means no future sample will ever arrive, so a
    /// stale number is not "waiting", it is off.
    let statusLineUnwired: Bool

    var remainingPercent: Int { max(0, 100 - usedPercent) }
    var tint: Color { QuotaPresentation.severity(usedPercent: usedPercent).tint }
    /// How much of the ring is drawn: what has been spent.
    var fraction: Double { min(1, max(0, Double(usedPercent) / 100)) }

    func resetText(now: Date) -> String? {
        resetsAt.map { QuotaPresentation.resetCountdown(from: $0, now: now) }
    }

    /// Why the number should not be trusted as of now, if it should not: the
    /// forwarder is off, or the reading has an age. Nil while it is live.
    func warningText(now: Date) -> String? {
        if statusLineUnwired { return String(localized: "Status line off") }
        if isStale, let observedAt { return QuotaPresentation.age(from: observedAt, now: now) }
        return nil
    }

    /// One line for a tooltip: "Weekly 78% left · resets in 3d 11h". The share
    /// is what remains, as every other quota reading in the app states it; the
    /// bar and the ring beside it fill with what has been spent.
    func summaryLine(now: Date) -> String {
        var text = "\(windowName) \(remainingPercent)% " + String(localized: "left")
        if let warning = warningText(now: now) { text += " · \(warning)" }
        else if let reset = resetText(now: now) { text += " · \(reset)" }
        return text
    }

    /// The agent's own allowance; nil when the agent has no account provider
    /// (Copilot, OpenCode…), its collection is off, or nothing could be read.
    static func read(_ agent: AgentKind, model: MenuBarModel, now: Date) -> AgentQuotaReading? {
        guard let provider = AccountUsageProvider.allCases.first(where: { $0.agentKind == agent }) else { return nil }
        return read(provider, model: model, now: now)
    }

    static func read(_ provider: AccountUsageProvider, model: MenuBarModel, now: Date) -> AgentQuotaReading? {
        guard model.isUsageCollectionEnabled(provider) else { return nil }
        let state = model.usageState(for: provider)
        guard let window = state.snapshot?.excludingExpiredWindows(at: now).displayWindows
            .max(by: { $0.usedPercent < $1.usedPercent }) else { return nil }
        return AgentQuotaReading(provider: provider, usedPercent: window.usedPercent,
                                 windowName: windowLabel(window, provider: provider),
                                 resetsAt: window.resetsAt, isStale: state.isStale,
                                 observedAt: state.snapshot?.fetchedAt,
                                 statusLineUnwired: model.usageStatusLineUnwired(provider))
    }

    /// The fleet's tightest reading — what the rail's "All agents" entry is
    /// ringed by, since that is the allowance about to stop the day's work.
    static func tightest(model: MenuBarModel, now: Date) -> AgentQuotaReading? {
        AccountUsageProvider.allCases.compactMap { read($0, model: model, now: now) }
            .max { $0.usedPercent < $1.usedPercent }
    }

    static func windowLabel(_ window: AccountUsageWindow, provider: AccountUsageProvider) -> String {
        if let label = window.label, !label.isEmpty { return label }
        guard let minutes = window.windowDurationMinutes else { return String(localized: "Window") }
        if minutes % 10_080 == 0 { return String(localized: "\(minutes / 10_080)-week") }
        if minutes % 1_440 == 0 { return String(localized: "\(minutes / 1_440)-day") }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60)-hour") }
        return String(localized: "\(minutes)-minute")
    }

    /// Why a provider has no reading right now, in the few words a row has.
    /// `filtered` is the snapshot with expired windows already removed. A
    /// provider that has a reading but no live window has not failed — its
    /// window reset and the source has not reported the new one yet, which is
    /// a different thing from "loading" and from "unavailable".
    static func shortReason(_ state: AccountUsageState, filtered: AccountUsageSnapshot?,
                            unwiredStatusLine: Bool = false) -> String {
        // No forwarder means no future sample, so "waiting" would be a lie.
        if unwiredStatusLine { return String(localized: "Status line off") }
        if state.snapshot != nil, filtered?.displayWindows.isEmpty ?? true,
           state.unavailableReason == nil || state.unavailableReason == .cachedData {
            return String(localized: "Awaiting reset")
        }
        guard let reason = state.unavailableReason else { return String(localized: "No reading") }
        switch reason {
        case .notLoggedIn: return String(localized: "Signed out")
        case .offline: return String(localized: "Offline")
        case .rateLimited: return String(localized: "Rate-limited")
        case .collectionDisabled: return String(localized: "Off")
        case .awaitingLiveSample: return String(localized: "No session yet")
        case .notYetLoaded, .cachedData: return String(localized: "Loading")
        default: return String(localized: "Unavailable")
        }
    }
}
