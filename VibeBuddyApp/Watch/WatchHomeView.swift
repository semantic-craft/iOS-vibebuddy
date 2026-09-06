import SwiftUI
import VibeBuddyKit

/// The default home answers one question — does anything need me? — and keeps
/// weekly allowance as secondary resource health. When a session is actually
/// blocked, the same page becomes the alert instead of burying it behind a swipe.
struct WatchHomeView: View {
    @ObservedObject var store: WatchStateStore
    let state: WatchDashboardState
    let connection: WatchConnection
    let now: Date

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    WatchConnectionBanner(connection: connection)
                    if let alert = state.topAlert {
                        WatchAlertCard(store: store, alert: alert, now: now,
                                       alsoWaiting: state.alerts.count - 1)
                    } else {
                        WatchCalmHeader(state: state, connection: connection)
                    }
                    WatchCountsRow(counts: state.counts, stuck: state.stuck)
                    WatchQuotaStrips(state: state, now: now)
                    WatchFooter(state: state, connection: connection, now: now)
                }
                .padding(.top, 2)
                // Clear the page indicator, so the last line is never half-hidden.
                .padding(.bottom, 14)
            }
            .navigationTitle("vibebuddy")
        }
    }
}

private struct WatchCalmHeader: View {
    let state: WatchDashboardState
    let connection: WatchConnection

    var body: some View {
        // With sessions running, the cat sits beside its line so the counts
        // still land on the first screen of a 40mm watch. With nothing running
        // there is nothing to make room for, so the empty state gets the centred
        // composition and room to explain itself.
        if state.counts.isEmpty {
            // Nothing known is not the same as nothing running: say which.
            VStack(spacing: 6) {
                WatchCat(state: state.buddyState)
                Text(connection.isCurrent ? "No sessions" : "No recent update")
                    .font(CompanionType.font(15, .black))
                    .multilineTextAlignment(.center)
                Text(connection.advice ?? "Start a session on your Mac and it shows up here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        } else {
            // Round 5: the cat says one line, the rest sits under it.
            HStack(spacing: 8) {
                WatchCat(state: state.buddyState, width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CompanionCopy.moodLine(state.presentation))
                        .font(CompanionType.font(14, .black))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    let rest = CompanionCopy.restLine(state.presentation)
                    if !rest.isEmpty {
                        Text(rest)
                            .font(CompanionType.font(10, .bold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The three canonical buckets, in the app's one status vocabulary: colour,
/// symbol, and word together, so the reading never depends on colour alone.
///
/// One bucket per line rather than three columns — at 40mm three columns force
/// "Needs response" to hyphenate, and a hyphenated status word is worse than a
/// slightly taller list.
struct WatchCountsRow: View {
    let counts: WatchSessionCounts
    /// Sessions whose last turn ended badly. The three buckets cannot say this,
    /// so it gets its own line — and only when there is something to say.
    var stuck: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(WatchBucket.allCases, id: \.self) { bucket in
                row(symbol: bucket.symbolName, value: bucket.count(in: counts),
                    accent: CompanionPalette.status(bucket.presentation), title: bucket.title)
            }
            if stuck > 0 {
                row(symbol: TaskPresentationState.error.symbolName, value: stuck,
                    accent: CompanionPalette.status(.error),
                    title: "Stuck")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(symbol: String, value: Int,
                     accent: Color, title: LocalizedStringResource) -> some View {
        let tint = value > 0 ? accent : Color.secondary
        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 11)
                .foregroundStyle(tint)
            Text(value, format: .number)
                .font(CompanionType.font(18, .black))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value, format: .number))
    }
}

/// Weekly allowance as a health indicator, not a dashboard. Detail lives one
/// swipe away on the quota page.
struct WatchQuotaStrips: View {
    let state: WatchDashboardState
    let now: Date

    var body: some View {
        if !state.quotas.isEmpty {
            VStack(spacing: 4) {
                ForEach(state.quotas) { quota in
                    strip(quota)
                }
            }
        }
    }

    private func strip(_ quota: ProviderQuota) -> some View {
        let freshness = quota.freshness(now: now)
        return HStack(spacing: 6) {
            Text(quota.provider.displayName)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 44, alignment: .leading)
            if let remaining = quota.window(.weekly).currentRemainingPercent(now: now) {
                ProgressView(value: Double(remaining), total: 100)
                    .tint(freshness == .stale ? Color.secondary
                          : (remaining <= 10 ? CompanionPalette.status(.requiresInput) : CompanionPalette.accent))
                Text(WatchFormat.percent(remaining))
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            } else {
                Text(quota.window(.weekly).status(now: now) == .awaitingReset ? "Reset reached · awaiting update" : "Window unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let symbol = freshness.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(quota.provider.displayName))
        .accessibilityValue(Text(WatchQuotaVoice.summary(quota, freshness: freshness, now: now)))
    }
}
