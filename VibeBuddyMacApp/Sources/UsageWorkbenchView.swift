import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// Account quota is account-level, not task-level, so it no longer rides along
/// with whichever session happens to be selected. It lives in two places: a
/// always-on plinth under the project list (one reading per provider, enough to
/// know whether you can keep working), and the Usage tab, which holds every
/// window, credits, spend and the local token estimate.
struct QuotaPlinth: View {
    @ObservedObject var model: MenuBarModel

    private var providers: [AccountUsageProvider] {
        AccountUsageProvider.allCases.filter { model.isUsageCollectionEnabled($0) }
    }

    var body: some View {
        if !providers.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 9) {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        Text("Account quota")
                            .font(MacTheme.font(10, .semibold)).foregroundStyle(MacTheme.ink3)
                            .textCase(.uppercase).kerning(0.6)
                        Spacer(minLength: 4)
                        if let updated = latestFetch {
                            Text(updated, style: .time)
                                .font(MacTheme.mono(9)).foregroundStyle(MacTheme.ink3)
                        }
                    }
                    ForEach(providers, id: \.self) { provider in
                        row(provider, now: context.date)
                    }
                    if let spend = todaySpend {
                        Divider()
                        HStack {
                            Text("Today's spend").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                            Spacer(minLength: 4)
                            Text(spend).font(MacTheme.mono(10, .semibold)).foregroundStyle(MacTheme.ink)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
    }

    /// One provider, one window: the window closest to running out, because
    /// that is the one that decides whether the next turn goes through.
    @ViewBuilder private func row(_ provider: AccountUsageProvider, now: Date) -> some View {
        let state = model.usageState(for: provider)
        let snapshot = state.snapshot?.excludingExpiredGrokWindows(at: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(provider.displayName).font(MacTheme.font(11, .medium))
                Spacer(minLength: 4)
                if let window = tightest(snapshot) {
                    Text("\(max(0, 100 - window.usedPercent))%")
                        .font(MacTheme.mono(11, .semibold))
                        .foregroundStyle(QuotaPresentation.severity(usedPercent: window.usedPercent).tint)
                } else {
                    Text(Self.shortReason(state)).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
                }
            }
            if let window = tightest(snapshot) {
                QuotaBullet(usedPercent: window.usedPercent,
                            pacePercent: AccountUsageSummaryView.pacePercent(window, now: now),
                            height: 8)
                HStack(spacing: 4) {
                    Text(windowName(window, provider: provider))
                    Spacer(minLength: 4)
                    if state.isStale {
                        Text("stale").foregroundStyle(QuotaPresentation.Severity.warning.tint)
                    } else if let reset = window.resetsAt {
                        Text(QuotaPresentation.resetCountdown(from: reset, now: now))
                    }
                }
                .font(MacTheme.font(9)).foregroundStyle(MacTheme.ink3)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tightest(_ snapshot: AccountUsageSnapshot?) -> AccountUsageWindow? {
        snapshot?.displayWindows.max { $0.usedPercent < $1.usedPercent }
    }

    private func windowName(_ window: AccountUsageWindow, provider: AccountUsageProvider) -> String {
        if let label = window.label, !label.isEmpty { return label }
        guard let minutes = window.windowDurationMinutes else { return String(localized: "Window") }
        if minutes % 10_080 == 0 { return String(localized: "\(minutes / 10_080)-week") }
        if minutes % 1_440 == 0 { return String(localized: "\(minutes / 1_440)-day") }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60)-hour") }
        return String(localized: "\(minutes)-minute")
    }

    static func shortReason(_ state: AccountUsageState) -> String {
        guard let reason = state.unavailableReason else { return String(localized: "No reading") }
        switch reason {
        case .notLoggedIn: return String(localized: "Signed out")
        case .offline: return String(localized: "Offline")
        case .rateLimited: return String(localized: "Rate-limited")
        case .collectionDisabled: return String(localized: "Off")
        case .notYetLoaded, .cachedData: return String(localized: "Loading")
        default: return String(localized: "Unavailable")
        }
    }

    private var latestFetch: Date? {
        providers.compactMap { model.usageState(for: $0).snapshot?.fetchedAt }.max()
    }

    private var todaySpend: String? {
        guard let window = model.tokenConsumption?.windows.first(where: { $0.kind == .today }),
              !window.counts.isEmpty else { return nil }
        return "\(TokenConsumptionSnapshot.formatUSD(window.counts.estimatedUSD)) · \(TokenConsumptionSnapshot.formatTokens(window.counts.totalTokens))"
    }
}

/// The Usage tab: every provider's windows in full, then the local token
/// estimate in its own section. Two different things — allowance left versus
/// money spent — so they share a page but never a row.
struct UsageWorkbenchView: View {
    @ObservedObject var model: MenuBarModel
    @State private var selection: AccountUsageProvider?

    private var providers: [AccountUsageProvider] {
        AccountUsageProvider.allCases.filter { model.isUsageCollectionEnabled($0) }
    }
    private var selected: AccountUsageProvider? { selection ?? providers.first }

    var body: some View {
        if providers.isEmpty {
            ContentUnavailableView("No usage sources are on",
                                   systemImage: "gauge.with.dots.needle.0percent",
                                   description: Text("Turn a provider on in Settings › Usage to collect its account quota."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MacTheme.bg)
        } else {
            HSplitView {
                providerRail
                detail
            }
        }
    }

    private var providerRail: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(providers, id: \.self) { provider in
                        Button { selection = provider } label: {
                            railRow(provider, now: context.date)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected == provider ? .isSelected : [])
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 180, idealWidth: 210, maxWidth: 280, maxHeight: .infinity)
        .background(MacTheme.bg2)
    }

    private func railRow(_ provider: AccountUsageProvider, now: Date) -> some View {
        let state = model.usageState(for: provider)
        let window = state.snapshot?.excludingExpiredGrokWindows(at: now).displayWindows
            .max { $0.usedPercent < $1.usedPercent }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.displayName).font(MacTheme.font(12, .medium))
                Spacer(minLength: 4)
                if let window {
                    Text("\(max(0, 100 - window.usedPercent))%")
                        .font(MacTheme.mono(11, .semibold))
                        .foregroundStyle(QuotaPresentation.severity(usedPercent: window.usedPercent).tint)
                }
            }
            if let window {
                QuotaBullet(usedPercent: window.usedPercent,
                            pacePercent: AccountUsageSummaryView.pacePercent(window, now: now),
                            height: 8)
            } else {
                Text(QuotaPlinth.shortReason(state)).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected == provider ? MacTheme.bg3 : .clear,
                    in: RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous))
        .overlay {
            if selected == provider {
                RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                    .strokeBorder(MacTheme.line, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let provider = selected {
                    let state = model.usageState(for: provider)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.displayName)
                            .font(MacTheme.font(20, .semibold))
                            .kerning(CompanionType.tracking(20))
                        if let plan = state.snapshot?.planType, !plan.isEmpty {
                            Text(plan).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                        }
                    }
                    AccountUsageSummaryView(provider: provider, state: state)
                        .font(MacTheme.font(12))
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .companionCard(radius: MacTheme.panelRadius)
                }
                section("Local token spend",
                        note: String(localized: "Estimated from local Claude Code and Codex logs — not an invoice, and not the same thing as account allowance."))
                TokenConsumptionSummaryView(snapshot: model.tokenConsumption)
                    .font(MacTheme.font(12))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .companionCard(radius: MacTheme.panelRadius)
            }
            .padding(16)
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(MacTheme.font(10, .semibold)).foregroundStyle(MacTheme.ink3)
                    .textCase(.uppercase).kerning(0.6)
                Rectangle().fill(MacTheme.line).frame(height: 1)
            }
            Text(note).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}
