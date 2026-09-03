import SwiftUI
import VibeBuddyKit

/// Weekly allowance in full: remaining first, then the context that makes a
/// percentage useful — when it resets, how the short window looks, how old the
/// reading is. Codex and Claude are always shown apart, and each carries its own
/// freshness, so a healthy source never covers for a broken one.
struct WatchQuotaView: View {
    let state: WatchDashboardState
    let connection: WatchConnection
    let now: Date

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    WatchConnectionBanner(connection: connection)
                    if state.quotas.isEmpty {
                        Text("No quota sources")
                            .font(.headline)
                        Text("Sign in to Codex or Claude Code on your Mac to see weekly allowance here.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        ForEach(state.quotas) { quota in
                            WatchQuotaDetail(quota: quota, now: now)
                        }
                    }
                    WatchFooter(state: state, connection: connection, now: now)
                }
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            .navigationTitle("Quota")
        }
    }
}

private struct WatchQuotaDetail: View {
    let quota: ProviderQuota
    let now: Date

    var body: some View {
        let freshness = quota.freshness(now: now)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.provider.displayName)
                    .font(.headline)
                Spacer(minLength: 4)
                if let remaining = quota.weeklyRemainingPercent {
                    Text(WatchFormat.percent(remaining))
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(freshness == .stale ? .secondary : .primary)
                }
            }

            if let remaining = quota.weeklyRemainingPercent {
                ProgressView(value: Double(remaining), total: 100)
                    .tint(freshness == .stale ? .secondary : .primary)
                row("Weekly remaining", resetText(quota.weeklyResetsAt))
                if let short = quota.shortWindowRemainingPercent {
                    row("5-hour window", String(localized: "\(WatchFormat.percent(short)) left"))
                }
            }

            HStack(spacing: 4) {
                if let symbol = freshness.symbolName {
                    Image(systemName: symbol).font(.system(size: 9))
                }
                Text(statusText(freshness))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(quota.provider.displayName))
        .accessibilityValue(Text(WatchQuotaVoice.summary(quota, freshness: freshness)))
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func resetText(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return String(localized: "Reset time unknown") }
        return String(localized: "Resets in \(WatchFormat.duration(resetsAt.timeIntervalSince(now)))")
    }

    /// Stale keeps the last number on screen with its age; unavailable says why
    /// instead of pretending the allowance is spent.
    private func statusText(_ freshness: QuotaFreshness) -> String {
        switch freshness {
        case .live:
            return WatchFormat.updated(quota.age(now: now))
        case .stale:
            return String(localized: "Stale · \(WatchFormat.updated(quota.age(now: now)))")
        case .unavailable:
            // The Mac's own diagnostic, kept verbatim behind a localized label.
            guard let reason = quota.unavailableReason else { return String(localized: "Unavailable") }
            return String(localized: "Unavailable · \(reason)")
        }
    }
}
