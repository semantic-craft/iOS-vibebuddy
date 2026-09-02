import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct AccountUsageSummaryView: View {
    let provider: AccountUsageProvider
    let state: AccountUsageState
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            if let snapshot = state.snapshot {
                if snapshot.windows.isEmpty {
                    Label("No quota windows supplied", systemImage: "gauge.with.dots.needle.0percent")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.windows) { window in
                        windowRow(window)
                    }
                }

                if !compact, snapshot.latestDailyTokens != nil || snapshot.lifetimeTokens != nil {
                    HStack(spacing: 12) {
                        if let tokens = snapshot.latestDailyTokens {
                            LabeledContent("Latest day", value: tokens.formatted())
                        }
                        if let tokens = snapshot.lifetimeTokens {
                            LabeledContent("Lifetime", value: tokens.formatted())
                        }
                    }
                    .font(.caption)
                }

                HStack(spacing: 5) {
                    Text("Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    if let plan = snapshot.planType, !plan.isEmpty {
                        Text("· \(plan)")
                    }
                    if state.isStale {
                        Text("· Stale").foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let reason = state.unavailableReason {
                Label(reason.displayText(provider: provider), systemImage: reasonIcon(reason))
                    .font(.caption)
                    .foregroundStyle(reason == .collectionDisabled ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if reason != .collectionDisabled, let retry = state.nextRefreshAt, retry > Date() {
                    Text("Retry \(retry, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func windowRow(_ window: AccountUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(windowTitle(window)).font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text("\(window.usedPercent)% used")
                    .font(.caption.monospacedDigit())
            }
            ProgressView(value: Double(window.usedPercent), total: 100)
                .tint(window.usedPercent >= 90 ? .orange : .accentColor)
            if let reset = window.resetsAt {
                Text("Resets \(reset, style: .relative) · \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Reset time unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func windowTitle(_ window: AccountUsageWindow) -> String {
        guard let minutes = window.windowDurationMinutes else {
            return window.kind == .primary ? "Primary window" : "Secondary window"
        }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080)-week window" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }

    private func reasonIcon(_ reason: AccountUsageUnavailableReason) -> String {
        switch reason {
        case .collectionDisabled: "pause.circle"
        case .notLoggedIn: "person.crop.circle.badge.exclamationmark"
        case .offline: "wifi.slash"
        case .rateLimited: "hourglass"
        case .timedOut: "clock.badge.exclamationmark"
        case .incompatibleFormat: "questionmark.app.dashed"
        case .providerUnavailable: "terminal"
        case .cachedData, .notYetLoaded: "arrow.clockwise"
        case .unknown: "exclamationmark.triangle"
        }
    }
}
struct AccountUsageSettings: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("accountUsageAlertThreshold") private var alertThreshold = 90

    var body: some View {
        Form {
            Section {
                ForEach(AccountUsageProvider.allCases, id: \.self) { provider in
                    Toggle("Collect \(provider.displayName) usage", isOn: Binding(
                        get: { model.isUsageCollectionEnabled(provider) },
                        set: { model.setUsageCollectionEnabled($0, provider: provider) }
                    ))
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Codex reads its official local app-server. Claude runs the official read-only /usage command without session persistence or hooks. No credentials, account IDs, or raw responses are stored or logged. Turning either source off leaves session monitoring and notifications running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Quota alert") {
                Picker("Quota alert", selection: $alertThreshold) {
                    Text("Off").tag(0)
                    Text("80%").tag(80)
                    Text("90%").tag(90)
                    Text("95%").tag(95)
                }
                Text("One threshold applies to both providers. Alerts identify the provider, respect quiet mode and quiet hours, and are not repeated after restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Current usage") {
                ForEach(AccountUsageProvider.allCases, id: \.self) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(provider.displayName).font(.headline)
                        AccountUsageSummaryView(
                            provider: provider,
                            state: model.usageState(for: provider)
                        )
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .formStyle(.grouped)
    }
}
