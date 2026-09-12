import SwiftUI
import VibeBuddyKit

/// Usage sheet: local token spend plus the account quota readings relayed to the Watch.
struct AccountQuotaView: View {
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var connection: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    Section {
                        if connection.pairing == nil && !connection.demo {
                            Text("Pair with your Mac to see usage.")
                        } else {
                            Text(connection.pairing?.macName ?? (connection.demo ? "Demo" : "Mac"))
                            if connection.pairing != nil, dashboard.state != .connected {
                                Label("Mac unreachable · saved readings only", systemImage: "wifi.slash")
                            }
                        }
                    } footer: {
                        Text("Account quota is what each account has left. Token spend below is estimated from local Claude Code and Codex logs on the Mac — not an invoice.")
                    }
                    // Demo mode has readings but no pairing, and a forgotten
                    // pairing still has its last saved readings worth showing.
                    if connection.pairing != nil || connection.demo {
                        ForEach(AccountUsageProvider.allCases) { provider in
                            let quota = dashboard.lastProviderQuota.first { $0.provider == provider }
                            Section("\(provider.displayName) quota") {
                                if let quota {
                                    if let account = quota.accountLabel {
                                        Text(account).font(.caption).foregroundStyle(.secondary)
                                    }
                                    let windows = Self.windows(quota)
                                    if windows.isEmpty {
                                        Text("Quota unavailable")
                                        if let observed = quota.observedAt {
                                            Text("Updated: \(observed.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                                        reading(window, now: context.date)
                                    }
                                    if let credits = quota.credits {
                                        LabeledContent(credits.label ?? "Credits", value: QuotaPresentation.creditsLine(credits))
                                        if let reset = credits.resetsAt {
                                            Text(QuotaPresentation.resetLine(from: reset, now: context.date))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    if let spend = quota.spend, !spend.isEmpty {
                                        ForEach(spend) { row in
                                            LabeledContent(row.label, value: QuotaPresentation.spendLine(row))
                                        }
                                    }
                                    if let reason = quota.unavailableReason {
                                        Text(reason).font(.callout).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("Not provided by this Mac")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let consumption = dashboard.lastTokenConsumption {
                        ForEach(consumption.windows) { window in
                            Section("Token spend · \(window.kind.title)") {
                                if window.counts.isEmpty {
                                    Text("No spend in this window")
                                        .foregroundStyle(.secondary)
                                } else {
                                    LabeledContent("Estimated cost", value: TokenConsumptionSnapshot.formatUSD(window.counts.estimatedUSD))
                                    LabeledContent("Tokens", value: TokenConsumptionSnapshot.formatTokens(window.counts.totalTokens))
                                    LabeledContent("Billed / cache", value: "\(TokenConsumptionSnapshot.formatTokens(window.counts.billedTokens)) · \(TokenConsumptionSnapshot.formatTokens(window.counts.cachedInputTokens))")
                                    LabeledContent("Sessions", value: "\(window.counts.sessionCount)")
                                    if !window.byAgent.isEmpty {
                                        Text("By agent").font(.caption).foregroundStyle(.secondary)
                                        ForEach(window.byAgent) { row in
                                            LabeledContent(row.label, value: "\(TokenConsumptionSnapshot.formatTokens(row.counts.totalTokens)) · \(TokenConsumptionSnapshot.formatUSD(row.counts.estimatedUSD))")
                                        }
                                    }
                                    if !window.byModel.isEmpty {
                                        Text("By model").font(.caption).foregroundStyle(.secondary)
                                        ForEach(Array(window.byModel.prefix(6))) { row in
                                            LabeledContent(row.label, value: TokenConsumptionSnapshot.formatTokens(row.counts.totalTokens))
                                        }
                                    }
                                    if !window.byProject.isEmpty {
                                        Text("By project").font(.caption).foregroundStyle(.secondary)
                                        ForEach(Array(window.byProject.prefix(4))) { row in
                                            LabeledContent(row.label, value: TokenConsumptionSnapshot.formatTokens(row.counts.totalTokens))
                                        }
                                    }
                                }
                            }
                        }
                        if let observed = dashboard.lastTokenConsumption?.observedAt {
                            Section {
                                Text("Token spend updated \(observed.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if connection.pairing != nil || connection.demo {
                        Section("Token consumption") {
                            Text("Not provided by this Mac yet")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

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

    static func title(_ window: QuotaWindow) -> String {
        let duration: String
        if let minutes = window.durationMinutes {
            if minutes % 1440 == 0 { duration = "\(minutes / 1440)-day window" }
            else if minutes % 60 == 0 { duration = "\(minutes / 60)-hour window" }
            else { duration = "\(minutes)-minute window" }
        } else { duration = "Window duration unknown" }
        guard let label = window.label, !label.isEmpty else { return duration }
        return "\(label) · \(duration)"
    }

    /// The same reading the Mac draws: a bullet with the spent bar over
    /// neutral 80/95 bands and a tick at the window's own pace, so "am I
    /// burning this faster than the clock" survives the trip to the phone.
    private func reading(_ window: QuotaWindow, now: Date) -> some View {
        let status = window.status(now: now)
        let remaining = window.currentRemainingPercent(now: now)
        let used = remaining.map { 100 - $0 }
        let pace = window.durationMinutes.flatMap { minutes in
            window.resetsAt.flatMap {
                QuotaPresentation.pacePercent(resetsAt: $0, windowMinutes: minutes, now: now)
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.title(window)).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let remaining {
                    Text("\(remaining)% left").monospacedDigit()
                        .foregroundStyle(QuotaPresentation.severity(usedPercent: 100 - remaining).tint)
                } else {
                    Text("Remaining unknown").foregroundStyle(.secondary)
                }
            }
            if let used {
                QuotaBullet(usedPercent: used, pacePercent: pace, height: 14)
            }
            Group {
                switch status {
                case .awaitingReset: Text("Reset reached · awaiting update")
                case .unavailable: Text("Reading unavailable")
                case .stale: Text("Stale · cached reading")
                case .live: Text(dashboard.state == .connected ? "Recent Mac reading" : "Cached · Mac unreachable")
                }
                if let reset = window.resetsAt {
                    Text(QuotaPresentation.resetLine(from: reset, now: now))
                } else {
                    Text("Reset time unknown")
                }
                if let remaining, let minutes = window.durationMinutes, minutes >= 60,
                   let reset = window.resetsAt,
                   let pace = QuotaPresentation.weeklyPace(
                    usedPercent: 100 - remaining, resetsAt: reset, windowMinutes: minutes, now: now) {
                    Text(pace.caption)
                        .foregroundStyle(pace == .ahead ? QuotaPresentation.Severity.warning.tint : Color.secondary)
                }
                if let observed = window.observedAt {
                    Text("Updated \(observed.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Update time unknown")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
