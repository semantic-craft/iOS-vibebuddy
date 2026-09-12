import SwiftUI
import VibeBuddyKit

/// A single provider at a time, with every independent allowance pool visible.
struct WatchQuotaView: View {
    let state: WatchDashboardState
    let connection: WatchConnection
    let now: Date
    @State private var provider: AccountUsageProvider

    init(state: WatchDashboardState, connection: WatchConnection, now: Date,
         selection: WatchQuotaSelection = .all) {
        self.state = state
        self.connection = connection
        self.now = now
        _provider = State(initialValue: selection.providers.first ?? .codex)
    }

    private var quota: ProviderQuota {
        var result = state.quota(provider)
            ?? .unavailable(provider, reason: String(localized: "Window unavailable"))
        if connection != .live { result.isCached = true }
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    WatchConnectionBanner(connection: connection)
                    if state.quotas.isEmpty {
                        Text("No quota sources")
                            .font(CompanionType.font(16, .semibold))
                        Text("Enable quota collection for your signed-in account on your Mac to see allowance here.")
                            .font(CompanionType.font(11))
                            .foregroundStyle(CompanionPalette.ink2)
                            .multilineTextAlignment(.center)
                    } else {
                        Picker("Platform", selection: $provider) {
                            ForEach(AccountUsageProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        WatchQuotaDetail(quota: quota, now: now)
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
            if let account = quota.accountLabel {
                Text(account).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            }
            let standard = QuotaWindowKind.allCases.map { quota.window($0) }.filter {
                $0.remainingPercent != nil || $0.durationMinutes != nil || $0.resetsAt != nil || $0.label != nil
            }
            let availableReadings = standard + (quota.otherWindows ?? []).map(cachedReading)
            let readings = availableReadings.isEmpty ? [quota.displayWindow()] : availableReadings
            if !readings.isEmpty {
                LazyVGrid(columns: readings.count == 1 ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 78))], spacing: 12) {
                    ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                        VStack(spacing: 5) {
                            WatchAllowanceRing(reading: reading, now: now, provider: quota.provider)
                                .frame(width: 64, height: 64)
                            Text(reading.label ?? WatchQuotaVoice.windowName(reading))
                                .font(CompanionType.font(11))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 72)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Remaining").font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            }
            ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                window(reading, title: WatchQuotaVoice.windowName(reading))
            }
            Text(WatchFormat.updated(quota.age(now: now)))
                .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            if let observedAt = quota.observedAt {
                Text(observedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            }
            if let reason = quota.unavailableReason {
                Text(reason).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
                Text("Check the quota source on your Mac.")
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cachedReading(_ reading: QuotaWindow) -> QuotaWindow {
        var result = reading
        result.isCached = reading.isCached == true || quota.isCached == true
        return result
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
                    .tint(status == .stale
                          ? CompanionPalette.ink3
                          : QuotaPresentation.tint(identity: .primary, usedPercent: 100 - remaining))
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
        .font(CompanionType.font(11))
        .foregroundStyle(status == .live ? CompanionPalette.ink : CompanionPalette.ink2)
    }
}

/// Missing and reset readings have a dashed track; a real zero has a solid one.
private struct WatchAllowanceRing: View {
    let reading: QuotaWindow
    let now: Date
    let provider: AccountUsageProvider

    /// Provider identity while there is room; the severity tint once the
    /// window crosses 80%, so the ring that is about to run out stops looking
    /// like the other four.
    private var tint: Color {
        guard reading.status(now: now) == .live else { return CompanionPalette.ink3 }
        return QuotaPresentation.tint(identity: identity,
                                      usedPercent: reading.currentRemainingPercent(now: now).map { 100 - $0 })
    }

    private var identity: Color {
        switch provider {
        case .codex: return .cyan
        case .claude: return .orange
        case .cursor: return .purple
        case .grok: return .indigo
        case .grokBot: return .mint
        }
    }

    var body: some View {
        let remaining = reading.currentRemainingPercent(now: now)
        let status = reading.status(now: now)
        ZStack {
            Circle().stroke(CompanionPalette.ink3.opacity(0.5),
                            style: StrokeStyle(lineWidth: 4, dash: remaining == nil ? [2, 5] : []))
            if let remaining, remaining > 0 {
                Circle().trim(from: 0, to: CGFloat(remaining) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                Text(status == .awaitingReset ? "↻" : remaining.map(WatchFormat.percent) ?? "—")
                    .font(CompanionType.font(16, .semibold)).monospacedDigit()
                    .minimumScaleFactor(0.7).lineLimit(1)
                if status == .stale {
                    Text("Cached reading").font(CompanionType.font(9)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }.padding(5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchQuotaVoice.windowName(reading))
        .accessibilityValue(Text(status == .awaitingReset
            ? String(localized: "Reset reached · awaiting update")
            : (remaining.map(WatchFormat.percent) ?? String(localized: "Unavailable"))
                + (status == .stale ? ", " + String(localized: "Cached reading") : "")))
    }
}
