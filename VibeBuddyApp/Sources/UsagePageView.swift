import SwiftUI
import VibeBuddyKit

/// The rules behind the Usage page's rows, kept out of the view so the tests
/// can pin them: which windows a provider shows, what they are called, which
/// one is tightest, and the one line under each bar.
enum UsageRows {
    /// Weekly and short first, then the independent pools (a Cursor or Grok
    /// billing period), each carrying the provider's cached flag.
    static func windows(_ quota: ProviderQuota) -> [QuotaWindow] {
        let standard = QuotaWindowKind.allCases.map { quota.window($0) }.filter {
            $0.remainingPercent != nil || $0.durationMinutes != nil || $0.resetsAt != nil || $0.label != nil
        }
        return standard + (quota.otherWindows ?? []).map { value in
            var value = value
            value.isCached = value.isCached == true || quota.isCached == true
            return value
        }
    }

    /// Subdivisions of the same allowance. Kept apart from `windows` so they
    /// cannot be mistaken for a provider's headline reading.
    static func scopedWindows(_ quota: ProviderQuota) -> [QuotaWindow] {
        (quota.scopedWindows ?? []).map { value in
            var value = value
            value.isCached = value.isCached == true || quota.isCached == true
            return value
        }
    }

    /// `Plan allowance · 30-day window`, or `7-day window` with no label.
    static func title(_ window: QuotaWindow) -> String {
        let duration: String
        if let minutes = window.durationMinutes {
            if minutes % 1440 == 0 { duration = String(localized: "\(minutes / 1440)-day window") }
            else if minutes % 60 == 0 { duration = String(localized: "\(minutes / 60)-hour window") }
            else { duration = String(localized: "\(minutes)-minute window") }
        } else { duration = String(localized: "Window duration unknown") }
        guard let label = window.label, !label.isEmpty else { return duration }
        return "\(label) · \(duration)"
    }

    /// The same name without "window", for the page's one-line summary.
    static func shortTitle(_ window: QuotaWindow) -> String {
        var duration: String?
        if let minutes = window.durationMinutes {
            if minutes % 1440 == 0 { duration = String(localized: "\(minutes / 1440)-day") }
            else if minutes % 60 == 0 { duration = String(localized: "\(minutes / 60)-hour") }
            else { duration = String(localized: "\(minutes)-minute") }
        }
        return [window.label.flatMap { $0.isEmpty ? nil : $0 }, duration].compactMap { $0 }.joined(separator: " · ")
    }

    /// The window with the least left, among every provider's headline
    /// windows. Scoped windows never count: they are detail, not a pool.
    static func tightest(_ quotas: [ProviderQuota], now: Date) -> (ProviderQuota, QuotaWindow)? {
        var best: (ProviderQuota, QuotaWindow, Int)?
        for provider in AccountUsageProvider.allCases {
            guard let quota = quotas.first(where: { $0.provider == provider }) else { continue }
            for window in windows(quota) {
                guard let remaining = window.currentRemainingPercent(now: now) else { continue }
                if best == nil || remaining < best!.2 { best = (quota, window, remaining) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// `Resets in 4d 2h · faster than pace`; `isWarning` when the window is
    /// being used up faster than its clock, which the page draws in amber.
    static func paceCaption(_ window: QuotaWindow, now: Date) -> (String, isWarning: Bool) {
        if window.status(now: now) == .awaitingReset {
            return (String(localized: "Reset reached · awaiting update"), false)
        }
        var parts: [String] = []
        var warning = false
        if let reset = window.resetsAt {
            parts.append(String(localized: "Resets \(QuotaPresentation.resetCountdown(from: reset, now: now))"))
        }
        if let remaining = window.currentRemainingPercent(now: now), let minutes = window.durationMinutes,
           minutes >= 60, let reset = window.resetsAt,
           let pace = QuotaPresentation.windowPace(usedPercent: 100 - remaining, resetsAt: reset,
                                                   windowMinutes: minutes, now: now) {
            switch pace {
            case .onTrack: parts.append(String(localized: "on pace"))
            case .spendingFaster: parts.append(String(localized: "faster than pace")); warning = true
            case .spendingSlower: parts.append(String(localized: "slower than pace"))
            }
        }
        guard !parts.isEmpty else { return (String(localized: "Reset time unknown"), false) }
        return (parts.joined(separator: " · "), warning)
    }

    /// `18 min ago` / `3 h ago`, for the unreachable banner.
    static func ageLine(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return String(localized: "\(minutes) min ago") }
        return String(localized: "\(minutes / 60) h ago")
    }
}

/// The Usage page (ios-usage-widgets, round 2 · Dense): a flat ledger of
/// every provider's windows, one bullet per window, then the local token
/// spend. Pushed from the hub's `chart.bar` circle and from the quota widgets.
struct UsagePageView: View {
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var connection: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    private var paired: Bool { connection.pairing != nil || connection.demo }
    private var reachable: Bool { connection.demo || dashboard.state == .connected }
    private var macTitle: String {
        let name = connection.pairing?.macName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return connection.demo ? String(localized: "Demo") : "Mac"
    }
    /// The newest reading the Mac relayed: the age the page admits to when
    /// the Mac cannot be reached.
    private var observedAt: Date? { dashboard.lastProviderQuota.compactMap(\.observedAt).max() }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                topBar(now: context.date)
                if paired {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if !reachable {
                                banner(now: context.date)
                            }
                            summary(now: context.date)
                            ForEach(AccountUsageProvider.allCases) { provider in
                                group(provider, now: context.date)
                            }
                            spend(now: context.date)
                        }
                    }
                } else {
                    PhoneEmptyState(symbol: "moon.zzz",
                                    title: String(localized: "Pair with your Mac to see usage"),
                                    text: String(localized: "Account quota and token spend are read on the Mac and relayed here.")) {
                        Button("Scan pairing code") {
                            // Unpaired, the root is the pairing screen.
                            connection.clear()
                            dismiss()
                        }
                        .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.accent)))
                    }
                    .padding(.top, 50)
                    Spacer(minLength: 0)
                }
            }
        }
        .background(CompanionPalette.bg)
        .toolbar(.hidden, for: .navigationBar)
        .tint(CompanionPalette.accent)
    }

    // MARK: chrome

    private func topBar(now: Date) -> some View {
        ZStack {
            Text("Usage")
                .font(CompanionType.font(16, .bold))
                .tracking(CompanionType.tracking(16))
                .foregroundStyle(CompanionPalette.ink)
            HStack {
                PhoneCircleButton("chevron.left") { dismiss() }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("usage-back")
                Spacer(minLength: 0)
                Text(!reachable && paired ? observedAt.map { PhoneRelativeTime.short($0, now: now) } ?? "" : "")
                    .font(CompanionType.font(12))
                    .foregroundStyle(CompanionPalette.ink2)
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(.horizontal, PhoneMetrics.gutter)
        .padding(.top, 6).padding(.bottom, 8)
    }

    private func banner(now: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
            Text(observedAt.map { String(localized: "Mac unreachable · saved readings from \(UsageRows.ageLine(since: $0, now: now))") }
                 ?? String(localized: "Mac unreachable · saved readings only"))
        }
        .font(CompanionType.font(12))
        .foregroundStyle(QuotaPresentation.Severity.warning.tint)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: CompanionType.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CompanionType.cardRadius, style: .continuous)
            .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline))
        .padding(.horizontal, PhoneMetrics.gutter).padding(.bottom, 10)
    }

    @ViewBuilder private func summary(now: Date) -> some View {
        Group {
            if let (quota, window) = UsageRows.tightest(dashboard.lastProviderQuota, now: now),
               let remaining = window.currentRemainingPercent(now: now) {
                let tint = QuotaPresentation.severity(usedPercent: 100 - remaining).tint
                let reading = Text("\(quota.provider.displayName) \(UsageRows.shortTitle(window)) \(remaining)%")
                    .font(CompanionType.font(14, .bold)).foregroundStyle(tint)
                Text("\(macTitle) · tightest: \(reading)")
            } else {
                Text(macTitle)
            }
        }
        .font(CompanionType.font(14))
        .foregroundStyle(CompanionPalette.ink2)
        .monospacedDigit()
        .padding(.horizontal, PhoneMetrics.gutter)
        .padding(.top, 10).padding(.bottom, 6)
    }

    // MARK: provider groups

    private func group(_ provider: AccountUsageProvider, now: Date) -> some View {
        let quota = dashboard.lastProviderQuota.first { $0.provider == provider }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AgentMark(agent: provider.agentKind, size: 14)
                    .frame(width: 22, height: 22)
                    .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(provider.displayName)
                    .font(CompanionType.font(16, .semibold))
                    .foregroundStyle(CompanionPalette.ink)
                if let account = quota?.accountLabel, !account.isEmpty {
                    Text(account)
                        .font(CompanionType.font(12))
                        .foregroundStyle(CompanionPalette.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PhoneMetrics.gutter)
            .padding(.top, 16).padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .id(provider)

            if let quota {
                let rows = UsageRows.windows(quota).map { ($0, false) } + UsageRows.scopedWindows(quota).map { ($0, true) }
                if rows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quota unavailable").font(CompanionType.font(15))
                        if let reason = quota.unavailableReason {
                            Text(reason).font(CompanionType.font(12))
                        }
                    }
                    .foregroundStyle(CompanionPalette.ink2)
                    .padding(.horizontal, PhoneMetrics.gutter).padding(.top, 4).padding(.bottom, 12)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { CompanionHairline() }
                    windowRow(row.0, scoped: row.1, now: now)
                }
                extras(quota, now: now)
            } else {
                Text("Not provided by this Mac")
                    .font(CompanionType.font(15))
                    .foregroundStyle(CompanionPalette.ink2)
                    .padding(.horizontal, PhoneMetrics.gutter).padding(.top, 4).padding(.bottom, 12)
            }
            CompanionHairline().padding(.top, 4)
        }
    }

    private func windowRow(_ window: QuotaWindow, scoped: Bool, now: Date) -> some View {
        let remaining = window.currentRemainingPercent(now: now)
        let pace = window.durationMinutes.flatMap { minutes in
            window.resetsAt.flatMap { QuotaPresentation.pacePercent(resetsAt: $0, windowMinutes: minutes, now: now) }
        }
        let caption = UsageRows.paceCaption(window, now: now)
        // Kit's 15-minute rule: the page is open, so its data is fresh
        // unless the Mac is gone or its own source is serving a cached value.
        let faded = !reachable || window.status(now: now) == .stale
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let title = Text(UsageRows.title(window)).font(CompanionType.font(15, .semibold))
                if scoped {
                    Text("\(Text("scoped · ").font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2))\(title)")
                } else {
                    title
                }
                Spacer(minLength: 8)
                if let remaining {
                    Text("\(remaining)% left")
                        .font(CompanionType.font(15, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(QuotaPresentation.severity(usedPercent: 100 - remaining).tint)
                } else {
                    Text("Remaining unknown")
                        .font(CompanionType.font(15))
                        .foregroundStyle(CompanionPalette.ink2)
                }
            }
            .foregroundStyle(CompanionPalette.ink)
            if let remaining {
                QuotaBullet(usedPercent: 100 - remaining, pacePercent: pace, height: 14)
                    .opacity(faded ? 0.45 : 1)
            }
            Text(caption.0)
                .font(CompanionType.font(12))
                .foregroundStyle(caption.isWarning ? QuotaPresentation.Severity.warning.tint : CompanionPalette.ink2)
        }
        .padding(.horizontal, PhoneMetrics.gutter)
        .padding(.top, 10).padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    /// Credits and extra-usage spend, when the local source reports them.
    @ViewBuilder private func extras(_ quota: ProviderQuota, now: Date) -> some View {
        if let credits = quota.credits {
            CompanionHairline()
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent(credits.label ?? String(localized: "Credits"), value: QuotaPresentation.creditsLine(credits))
                if let reset = credits.resetsAt {
                    Text(QuotaPresentation.resetLine(from: reset, now: now))
                        .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                }
            }
            .modifier(UsageLabeledRow())
        }
        ForEach(quota.spend ?? []) { row in
            CompanionHairline()
            LabeledContent(row.label, value: QuotaPresentation.spendLine(row))
                .modifier(UsageLabeledRow())
        }
    }

    // MARK: token spend

    @ViewBuilder private func spend(now: Date) -> some View {
        // Absent entirely when the Mac reports none — an empty section is
        // worse than no section.
        if let consumption = dashboard.lastTokenConsumption {
            VStack(alignment: .leading, spacing: 0) {
                Text("Token spend · from local logs")
                    .textCase(.uppercase)
                    .font(CompanionType.font(13, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(CompanionPalette.ink3)
                    .padding(.top, 18).padding(.bottom, 4)
                ForEach([TokenConsumptionWindowKind.today, .last7Days], id: \.self) { kind in
                    if let window = consumption.window(kind) {
                        spendRows(window)
                    }
                }
                let source = reachable
                    ? String(localized: "Recent Mac reading")
                    : "\(String(localized: "Cached · Mac unreachable")) · \(UsageRows.ageLine(since: consumption.observedAt, now: now))"
                Text("\(source) · list price, not an invoice.")
                    .font(CompanionType.font(12))
                    .foregroundStyle(CompanionPalette.ink3)
                    .padding(.top, 10)
            }
            .padding(.horizontal, PhoneMetrics.gutter)
            .padding(.bottom, 24)
        }
    }

    private func spendRows(_ window: TokenConsumptionWindow) -> some View {
        let title = window.kind == .today ? String(localized: "Today") : String(localized: "Last 7 days")
        let agents = window.byAgent.map { row in
            "\(AgentKind(rawValue: row.key)?.shortName ?? row.label) \(Self.usd(row.counts.estimatedUSD))"
        }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 2) {
            CompanionHairline()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).foregroundStyle(CompanionPalette.ink)
                Spacer(minLength: 8)
                Text(window.counts.isEmpty
                     ? String(localized: "No spend in this window")
                     : "\(TokenConsumptionSnapshot.formatTokens(window.counts.totalTokens)) · \(Self.usd(window.counts.estimatedUSD))")
                    .foregroundStyle(CompanionPalette.ink2)
                    .monospacedDigit()
            }
            .font(CompanionType.font(14))
            .padding(.top, 9)
            if !window.counts.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(agents)
                    Spacer(minLength: 8)
                    Text("\(window.counts.sessionCount) sessions")
                }
                .font(CompanionType.font(12))
                .foregroundStyle(CompanionPalette.ink3)
                .monospacedDigit()
            }
        }
        .padding(.bottom, 9)
        .accessibilityElement(children: .combine)
    }

    private static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
}

/// A `LabeledContent` row on the page's ground, in the row's type.
private struct UsageLabeledRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(CompanionType.font(14))
            .foregroundStyle(CompanionPalette.ink)
            .padding(.horizontal, PhoneMetrics.gutter)
            .padding(.vertical, 10)
    }
}
