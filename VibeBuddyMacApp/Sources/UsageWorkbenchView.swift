import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

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

    /// One bar for most providers — the pool closest to running out. Cursor
    /// runs two independent pools over the same billing period, so it gets one
    /// named bar each: picking between them would hide whichever is spent.
    private func railRow(_ provider: AccountUsageProvider, now: Date) -> some View {
        let state = model.usageState(for: provider)
        let snapshot = state.snapshot?.excludingExpiredWindows(at: now)
        let windows = snapshot?.headlineWindows() ?? []
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.displayName).font(MacTheme.font(12, .medium))
                Spacer(minLength: 4)
                if windows.count == 1, let window = windows.first {
                    Text("\(max(0, 100 - window.usedPercent))%")
                        .font(MacTheme.mono(11, .semibold))
                        .foregroundStyle(QuotaPresentation.severity(usedPercent: window.usedPercent).tint)
                }
            }
            if windows.isEmpty {
                Text(AgentQuotaReading.shortReason(state, filtered: snapshot,
                                                   unwiredStatusLine: model.usageStatusLineUnwired(provider)))
                    .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
            } else {
                ForEach(windows) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        if windows.count > 1 {
                            HStack(alignment: .firstTextBaseline) {
                                Text(AgentQuotaReading.windowLabel(window, provider: provider))
                                    .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(max(0, 100 - window.usedPercent))%")
                                    .font(MacTheme.mono(10, .semibold))
                                    .foregroundStyle(QuotaPresentation.severity(usedPercent: window.usedPercent).tint)
                            }
                        }
                        QuotaBullet(usedPercent: window.usedPercent,
                                    pacePercent: AccountUsageSummaryView.pacePercent(window, now: now),
                                    height: 8)
                    }
                }
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
