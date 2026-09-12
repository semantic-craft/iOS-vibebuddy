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
                        // An open task or quota sheet covers this card, so it
                        // stops being the one a Double Tap should resolve.
                        WatchAlertCard(store: store, alert: alert, now: now,
                                       alsoWaiting: state.alerts.count - 1,
                                       isFrontmost: store.taskLink == nil && store.quotaSelection == nil)
                    } else {
                        WatchCalmHeader(state: state, connection: connection)
                    }
                    WatchCountsRow(counts: state.counts)
                    followedTasks
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

    @ViewBuilder
    private var followedTasks: some View {
        if let source = state.sourceID, !source.isEmpty,
           let epoch = state.pairingEpoch, !epoch.isEmpty,
           !state.followedTasks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // The group cannot fold on a wrist: nothing else is on the page
                // to make room for, and a hidden task is a missed one.
                CompanionSectionHeader(title: Text("Followed tasks"), count: state.followedTasks.count)
                    .padding(.bottom, 4)
                ForEach(Array(state.followedTasks.enumerated()), id: \.element.id) { index, task in
                    Button {
                        store.openTask(WatchTaskLink(sourceID: source, pairingEpoch: epoch,
                            sessionID: task.sessionID, completionID: task.completionID).url)
                    } label: {
                        HStack(spacing: 6) {
                            StatusDot(state: task.presentation)
                            Text(task.title.isEmpty ? String(localized: "Unnamed task") : task.title)
                                .font(CompanionType.font(12))
                                .foregroundStyle(CompanionPalette.ink)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(CompanionPalette.ink3)
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(task.presentation.label), \(task.title.isEmpty ? String(localized: "Unnamed task") : task.title)"))
                    if index < state.followedTasks.count - 1 {
                        CompanionHairline(leading: WatchMetrics.dotLane)
                    }
                }
            }
        }
    }
}

private struct WatchCalmHeader: View {
    let state: WatchDashboardState
    let connection: WatchConnection

    var body: some View {
        // With sessions running, the status dot sits beside its line so the
        // counts still land on the first screen of a 40mm watch. With nothing
        // running there is nothing to make room for, so the empty state gets
        // the centred composition and room to explain itself.
        if state.counts.isEmpty {
            // Nothing known is not the same as nothing running: say which.
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(CompanionPalette.ink3)
                    .accessibilityHidden(true)
                Text(connection.isCurrent ? "No sessions" : "No recent update")
                    .font(CompanionType.font(14, .semibold))
                    .foregroundStyle(CompanionPalette.ink)
                    .multilineTextAlignment(.center)
                Text(connection.advice ?? "Start a session on your Mac and it shows up here.")
                    .font(CompanionType.font(10))
                    .foregroundStyle(CompanionPalette.ink2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        } else {
            // One dot for the whole snapshot, in the colour of what matters most.
            HStack(alignment: .top, spacing: 6) {
                StatusDot(state: state.presentation.primaryState)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CompanionCopy.moodLine(state.presentation))
                        .font(CompanionType.font(14, .semibold))
                        .foregroundStyle(CompanionPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    let rest = CompanionCopy.restLine(state.presentation)
                    if !rest.isEmpty {
                        Text(rest)
                            .font(CompanionType.font(10))
                            .monospacedDigit()
                            .foregroundStyle(CompanionPalette.ink2)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The three canonical buckets, in the app's one status vocabulary: a dot, the
/// word, and the count, so the reading never depends on colour alone.
///
/// One bucket per line rather than three columns — at 40mm three columns force
/// "Needs response" to hyphenate, and a hyphenated status word is worse than a
/// slightly taller list.
struct WatchCountsRow: View {
    let counts: WatchSessionCounts

    var body: some View {
        // A failed session is already counted under Needs you (`StateGroups`),
        // so there is no separate Stuck line: the alert card names it.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(WatchBucket.allCases.enumerated()), id: \.element) { index, bucket in
                row(state: bucket.presentation, value: bucket.count(in: counts), title: bucket.title)
                if index < WatchBucket.allCases.count - 1 {
                    CompanionHairline(leading: WatchMetrics.dotLane)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(state: TaskPresentationState, value: Int, title: LocalizedStringResource) -> some View {
        HStack(spacing: 6) {
            // An empty bucket keeps its place but not its colour.
            Circle()
                .fill(value > 0 ? CompanionPalette.status(state) : CompanionPalette.ink3)
                .frame(width: 7, height: 7)
            Text(title)
                .font(CompanionType.font(12))
                .foregroundStyle(value > 0 ? CompanionPalette.ink : CompanionPalette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Text(value, format: .number)
                .font(CompanionType.font(12))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? CompanionPalette.ink : CompanionPalette.ink3)
        }
        .padding(.vertical, 5)
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
        // Prefer weekly; fall back to short / otherWindows (Cursor/Grok monthly).
        let reading = quota.displayWindow(preferring: .weekly)
        return HStack(spacing: 6) {
            Text(quota.provider.displayName)
                .font(CompanionType.font(10))
                .foregroundStyle(CompanionPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 44, alignment: .leading)
            if let remaining = reading.currentRemainingPercent(now: now) {
                ProgressView(value: Double(remaining), total: 100)
                    .tint(freshness == .stale ? CompanionPalette.ink3
                          : (remaining <= 10 ? CompanionPalette.status(.requiresInput) : CompanionPalette.accent))
                Text(WatchFormat.percent(remaining))
                    .font(CompanionType.font(10))
                    .monospacedDigit()
                    .foregroundStyle(CompanionPalette.ink)
                    .frame(width: 32, alignment: .trailing)
            } else {
                Text(reading.status(now: now) == .awaitingReset ? "Reset reached · awaiting update" : "Window unavailable")
                    .font(CompanionType.font(10))
                    .foregroundStyle(CompanionPalette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let symbol = freshness.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(CompanionPalette.ink2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(quota.provider.displayName))
        .accessibilityValue(Text(WatchQuotaVoice.summary(quota, freshness: freshness, now: now)))
    }
}
