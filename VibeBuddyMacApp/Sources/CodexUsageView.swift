import SwiftUI
import VibeBuddyMacCore

struct CodexUsageSummaryView: View {
    let state: CodexUsageState
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
                Label(reason.displayText, systemImage: reasonIcon(reason))
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

    private func windowRow(_ window: CodexUsageWindow) -> some View {
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

    private func windowTitle(_ window: CodexUsageWindow) -> String {
        guard let minutes = window.windowDurationMinutes else {
            return window.kind == .primary ? "Primary window" : "Secondary window"
        }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080)-week window" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }

    private func reasonIcon(_ reason: CodexUsageUnavailableReason) -> String {
        switch reason {
        case .collectionDisabled: "pause.circle"
        case .notLoggedIn: "person.crop.circle.badge.exclamationmark"
        case .offline: "wifi.slash"
        case .rateLimited: "hourglass"
        case .timedOut: "clock.badge.exclamationmark"
        case .incompatibleFormat: "questionmark.app.dashed"
        case .codexUnavailable: "terminal"
        case .cachedData, .notYetLoaded: "arrow.clockwise"
        case .unknown: "exclamationmark.triangle"
        }
    }
}

struct CodexUsageSettings: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("codexUsageAlertThreshold") private var alertThreshold = 90

    var body: some View {
        Form {
            Section {
                Toggle("Collect Codex usage", isOn: Binding(
                    get: { model.codexUsageCollectionEnabled },
                    set: { model.setCodexUsageCollectionEnabled($0) }
                ))
                Picker("Quota alert", selection: $alertThreshold) {
                    Text("Off").tag(0)
                    Text("80%").tag(80)
                    Text("90%").tag(90)
                    Text("95%").tag(95)
                }
                .disabled(!model.codexUsageCollectionEnabled)
            } footer: {
                Text("Reads account usage through Codex's official local app-server. No credential files are read or logged. Turning this off stops usage work; session monitoring and its notifications keep running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Current usage") {
                CodexUsageSummaryView(state: model.codexUsageState)
            }
        }
        .formStyle(.grouped)
    }
}
