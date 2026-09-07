import SwiftUI
import VibeBuddyKit

/// Weekly allowance in full: remaining first, then the context that makes a
/// percentage useful — when it resets, how the short window looks, how old the
/// reading is. Each provider is shown apart with its own freshness, so a healthy
/// source never covers for a broken one.
struct WatchQuotaView: View {
    let state: WatchDashboardState
    let connection: WatchConnection
    let now: Date
    var selection: WatchQuotaSelection = .all

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    WatchConnectionBanner(connection: connection)
                    if state.quotas.isEmpty {
                        Text("No quota sources")
                            .font(.headline)
                        Text("Sign in to Codex, Claude, Cursor, or Grok on your Mac to see allowance here.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        ForEach(selection.providers) { provider in
                            let quota = state.quotas.first { $0.provider == provider } ?? .unavailable(provider, reason: String(localized: "Window unavailable"))
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
        VStack(alignment: .leading, spacing: 8) {
            Text(quota.provider.displayName).font(.headline)
            window(quota.window(.weekly), title: String(localized: "Weekly remaining"))
            window(quota.window(.short), title: quota.shortWindowDurationMinutes == nil ? String(localized: "Short window") : WatchQuotaVoice.windowName(quota.window(.short)))
            ForEach(Array((quota.otherWindows ?? []).enumerated()), id: \.offset) { _, reading in
                window(reading, title: WatchQuotaVoice.windowName(reading))
            }
            Text(WatchFormat.updated(quota.age(now: now)))
                .font(.caption2).foregroundStyle(.secondary)
            if let observedAt = quota.observedAt {
                Text(observedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let reason = quota.unavailableReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
                Text("Check the quota source on your Mac.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func window(_ reading: QuotaWindow, title: String) -> some View {
        let status = reading.status(now: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer(minLength: 2)
                Text(reading.currentRemainingPercent(now: now).map(WatchFormat.percent) ?? "—")
                    .monospacedDigit()
            }
            if let remaining = reading.currentRemainingPercent(now: now) {
                ProgressView(value: Double(remaining), total: 100)
                    .tint(status == .stale ? .secondary : .primary)
            }
            if status == .awaitingReset {
                Text("Reset reached · awaiting update")
                if let previous = reading.remainingPercent {
                    Text("Before reset: \(WatchFormat.percent(previous))")
                }
            } else if status == .unavailable {
                Text("Window unavailable")
            } else if status == .stale {
                Text("Cached reading")
            }
            if let reset = reading.resetsAt {
                Text(reset.formatted(date: .abbreviated, time: .shortened))
                if reset > now {
                    Text("Resets in \(WatchFormat.duration(reset.timeIntervalSince(now)))")
                } else {
                    Text("Reset was \(WatchFormat.duration(now.timeIntervalSince(reset))) ago")
                }
            } else {
                Text("Reset time unknown")
            }
        }
        .font(.caption2)
        .foregroundStyle(status == .live ? .primary : .secondary)
    }
}
