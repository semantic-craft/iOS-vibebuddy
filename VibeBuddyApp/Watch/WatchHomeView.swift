import SwiftUI
import VibeBuddyKit

/// The default home answers one question — does anything need me? — and keeps
/// weekly allowance as secondary resource health. When a session is actually
/// blocked, the same page becomes the alert instead of burying it behind a swipe.
struct WatchHomeView: View {
    let state: WatchDashboardState
    let now: Date

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let alert = state.topAlert {
                        WatchAlertCard(alert: alert, now: now,
                                       alsoWaiting: state.alerts.count - 1)
                    } else {
                        WatchCalmHeader(state: state)
                    }
                    WatchCountsRow(counts: state.counts)
                    WatchQuotaStrips(state: state, now: now)
                    WatchFooter(state: state, now: now)
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

    var body: some View {
        // With sessions running, the cat sits beside the headline so the three
        // counts still land on the first screen of a 40mm watch. With nothing
        // running there is nothing to make room for, so the empty state gets
        // the centred composition and room to explain itself.
        if state.counts.isEmpty {
            VStack(spacing: 6) {
                WatchPixelCat(state: state.buddyState)
                Text("No sessions")
                    .font(.headline)
                Text("Start a session on your Mac and it shows up here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 8) {
                WatchPixelCat(state: state.buddyState, size: CGSize(width: 36, height: 42))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nobody's waiting")
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(state.counts.working > 0
                         ? "\(state.counts.working) working"
                         : "All quiet")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(WatchBucket.allCases, id: \.self) { bucket in
                row(bucket)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ bucket: WatchBucket) -> some View {
        let value = bucket.count(in: counts)
        let accent = value > 0 ? bucket.color : Color.secondary
        return HStack(spacing: 6) {
            Image(systemName: bucket.symbolName)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 11)
                .foregroundStyle(accent)
            Text(value, format: .number)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
            Text(bucket.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bucket.title))
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

    private func strip(_ quota: WatchQuota) -> some View {
        let freshness = quota.freshness(now: now)
        return HStack(spacing: 6) {
            Text(quota.provider.displayName)
                .font(.caption2)
                .frame(width: 42, alignment: .leading)
            if let remaining = quota.weeklyRemainingPercent {
                ProgressView(value: Double(remaining), total: 100)
                    .tint(freshness == .stale ? .secondary : .primary)
                Text(WatchFormat.percent(remaining))
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            } else {
                Text("Unavailable")
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
        .accessibilityValue(Text(WatchQuotaVoice.summary(quota, freshness: freshness)))
    }
}
