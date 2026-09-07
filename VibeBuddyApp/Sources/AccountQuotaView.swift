import SwiftUI
import VibeBuddyKit

/// Read-only rendering of the exact account readings relayed to the Watch.
struct AccountQuotaView: View {
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var connection: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    Section {
                        if connection.pairing == nil {
                            Text("Pair with your Mac to see account quota.")
                        } else {
                            Text(connection.pairing?.macName ?? "Mac")
                            if dashboard.state != .connected {
                                Label("Mac unreachable · saved readings only", systemImage: "wifi.slash")
                            }
                        }
                    } footer: {
                        Text("Account allowance from your Mac, separate from a task's context usage. Manage accounts and quota sources on your Mac.")
                    }
                    if connection.pairing != nil {
                        ForEach(AccountUsageProvider.allCases) { provider in
                            let quota = dashboard.lastProviderQuota.first { $0.provider == provider }
                            Section(provider.displayName) {
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
                }
            }
            .navigationTitle("Account quota")
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

    private func reading(_ window: QuotaWindow, now: Date) -> some View {
        let status = window.status(now: now)
        let remaining = window.currentRemainingPercent(now: now)
        return VStack(alignment: .leading, spacing: 6) {
            Text(Self.title(window)).font(.headline)
            if let remaining {
                Text("\(remaining)% remaining").monospacedDigit()
                ProgressView(value: Double(remaining), total: 100)
            } else { Text("Remaining unknown") }
            switch status {
            case .awaitingReset:
                Text("Reset reached · awaiting update")
            case .unavailable:
                Text("Reading unavailable")
            case .stale:
                Text("Stale · cached reading")
            case .live:
                Text(dashboard.state == .connected ? "Recent Mac reading" : "Cached · Mac unreachable")
            }
            if let reset = window.resetsAt {
                Text("Resets: \(reset.formatted(date: .abbreviated, time: .shortened))")
            } else { Text("Reset time unknown") }
            if let observed = window.observedAt {
                Text("Updated: \(observed.formatted(date: .abbreviated, time: .shortened))")
            } else { Text("Update time unknown") }
        }
        .font(.callout)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
