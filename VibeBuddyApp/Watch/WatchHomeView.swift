import SwiftUI
import VibeBuddyKit

/// The home answers, in this order: how many things need you and which one
/// is first (the headline and the card); what else is waiting (rows you can
/// open);
/// and only then what is merely running, and the allowance. Counting tables,
/// the pet and logs do not get a line of a 40mm screen (ADR-0021).
struct WatchHomeView: View {
    @ObservedObject var store: WatchStateStore
    let state: WatchDashboardState
    let connection: WatchConnection
    let now: Date

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    WatchConnectionBanner(connection: connection)
                    WatchHeadline(state: state, connection: connection)
                    if let alert = state.topAlert {
                        // An open task or quota sheet covers this card, so it
                        // stops being the one a Double Tap should resolve.
                        WatchAlertCard(store: store, alert: alert, now: now, alsoWaiting: 0,
                                       isFrontmost: store.taskLink == nil && store.quotaSelection == nil)
                    }
                    alsoWaiting
                    unreadResults
                    tasks
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

    /// Every other blocked session: the alerts behind the card, then the
    /// sessions that stopped on an error. Each row opens the same detail the
    /// card sits on, so the second approval is one tap away rather than a
    /// swipe and a scroll.
    @ViewBuilder
    private var alsoWaiting: some View {
        let others = Array(state.alerts.dropFirst())
        let stuck = state.stuckTasks
        if !others.isEmpty || !stuck.isEmpty {
            WatchSection(title: Text("Also waiting"), count: others.count + stuck.count) {
                ForEach(others) { alert in
                    WatchSessionRow(state: .requiresInput,
                                    title: WatchSessionRow.title(for: alert),
                                    detail: "\(alert.agent.shortName) · \(alert.project)",
                                    trailing: WatchFormat.duration(alert.waitedFor(now: now))) {
                        store.openSession(alert.sessionId)
                    }
                }
                ForEach(stuck) { task in
                    WatchSessionRow(state: .error,
                                    title: task.title.isEmpty ? String(localized: "Unnamed task") : task.title,
                                    detail: WatchSessionRow.detail(agent: task.agent,
                                        task.summary.flatMap { $0.isEmpty ? nil : $0 }
                                            ?? String(localized: "Stopped with an error")),
                                    trailing: nil) {
                        store.openSession(task.sessionID)
                    }
                }
            }
        }
    }

    /// Individual current results remain accessible without the deleted Recap pager.
    @ViewBuilder
    private var unreadResults: some View {
        taskRows(state.unreadResults, title: Text("Results"))
    }

    /// A running count must have an openable task even at normal attention.
    @ViewBuilder
    private var tasks: some View {
        let listed = Set(state.alerts.map(\.sessionId))
        let followedIDs = Set(state.followedTasks.map(\.sessionID))
        let candidates = state.followedTasks + (state.workingTasks ?? []).filter {
            !followedIDs.contains($0.sessionID)
        }
        let rest = candidates.filter {
            !listed.contains($0.sessionID) && $0.presentation != .completeUnread && $0.presentation != .error
        }
        taskRows(rest, title: Text("Tasks"))
    }

    @ViewBuilder
    private func taskRows(_ tasks: [WatchFollowedTask], title: Text) -> some View {
        if let source = state.sourceID, !source.isEmpty,
           let epoch = state.pairingEpoch, !epoch.isEmpty, !tasks.isEmpty {
            WatchSection(title: title, count: tasks.count) {
                ForEach(tasks) { task in
                    WatchSessionRow(state: task.presentation,
                                    title: task.title.isEmpty ? String(localized: "Unnamed task") : task.title,
                                    detail: WatchSessionRow.detail(agent: task.agent, task.summary),
                                    trailing: nil) {
                        store.openTask(WatchTaskLink(sourceID: source, pairingEpoch: epoch,
                            sessionID: task.sessionID, completionID: task.completionID).url)
                    }
                }
            }
        }
    }

}

/// The first line of the home: how many things need you, in the colour of
/// what matters most, and what else is going on in one quiet line beneath.
/// With nothing known, the empty state says *which* nothing — no sessions,
/// or no recent word from the phone — and what to do about it.
private struct WatchHeadline: View {
    let state: WatchDashboardState
    let connection: WatchConnection

    var body: some View {
        if state.counts.isEmpty {
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
            HStack(alignment: .top, spacing: 6) {
                StatusDot(state: state.presentation.primaryState)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CompanionCopy.moodLine(state.presentation))
                        .font(CompanionType.font(13, .semibold))
                        .foregroundStyle(CompanionPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if state.presentation.needsYou > 0, state.counts.working > 0 {
                        Text("\(state.counts.working) working")
                            .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink2)
                    }
                    Text("Done \(state.counts.done) · \(state.presentation.completeUnread) unread")
                        .font(CompanionType.font(10)).monospacedDigit()
                        .foregroundStyle(CompanionPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A titled group of rows, in the flat grammar every surface shares: the
/// section header, rows on hairlines. It cannot fold on a wrist — a hidden
/// row is a missed one.
struct WatchSection<Rows: View>: View {
    let title: Text
    let count: Int
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompanionSectionHeader(title: title, count: count)
                .padding(.bottom, 2)
            rows()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One session, one line to read and one to place it: the dot says what kind
/// of thing it is, the title says which, the detail says whose and how long.
/// Tapping opens it. The whole row is the target — a 40mm screen has no room
/// for a chevron that is also the only tappable part.
struct WatchSessionRow: View {
    let state: TaskPresentationState
    let title: String
    let detail: String?
    let trailing: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row
            CompanionHairline(leading: WatchMetrics.dotLane)
        }
    }

    private var row: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                StatusDot(state: state)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(CompanionType.font(12, .medium))
                        .foregroundStyle(CompanionPalette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(CompanionType.font(10))
                            .foregroundStyle(CompanionPalette.ink2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(CompanionType.font(10))
                        .monospacedDigit()
                        .foregroundStyle(CompanionPalette.ink2)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CompanionPalette.ink3)
                        .padding(.top, 3)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(state.label), \(title)"))
        .accessibilityValue(Text([detail, trailing].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
    }

    /// Whose it is, then what it said: two tasks in the same project read the
    /// same on a 40mm screen until the agent is named (WR-10). Waiting rows
    /// already lead with it.
    static func detail(agent: AgentKind?, _ text: String?) -> String? {
        let said = text.flatMap { $0.isEmpty ? nil : $0 }
        let parts = [agent?.shortName, said].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The line that says what a waiting session is blocked on: the agent's
    /// own summary or question, else the kind of wait.
    static func title(for alert: WatchAlert) -> String {
        if alert.waitKind == .question, let request = alert.request, !request.isEmpty { return request }
        if let summary = alert.summary, !summary.isEmpty { return summary }
        if let request = alert.request, !request.isEmpty { return request }
        return alert.waitKind == .permission
            ? String(localized: "Needs approval") : String(localized: "Asked a question")
    }
}

/// Weekly allowance as a health indicator, not a dashboard. Detail lives one
/// swipe away on the quota page.
struct WatchQuotaStrips: View {
    let state: WatchDashboardState
    let now: Date

    var body: some View {
        if !state.quotas.isEmpty {
            // Tightest first: the allowance about to stop work is the one
            // worth the top line of the section (ADR-0031 reads the same way
            // on the rail and the strip).
            // One row per pool, and Cursor has two. The list is flat and sorted
            // by the number each row itself shows, so a pool with room never
            // rides above another provider's tighter row.
            VStack(spacing: 4) {
                ForEach(state.quotas.stripRowsLowestFirst(now: now)) { row in
                    let pools = row.quota.stripWindows(now: now)
                    strip(row.quota, reading: row.window, pool: pools.count > 1 ? row.window.label : nil)
                }
            }
        }
    }

    private func strip(_ quota: ProviderQuota, reading: QuotaWindow, pool: String?) -> some View {
        let freshness = quota.freshness(now: now)
        let agent = quota.provider.agentKind
        return HStack(spacing: 5) {
            // The allowance belongs to the agent, not to a provider name in a
            // list of its own: the same mark the rows and the detail carry.
            AgentAvatar(agent: agent, size: 16)
                .accessibilityHidden(true)
            // The short name keeps its fixed 38pt column so every bar starts at
            // the same x. A pool name is longer than any short name, so it may
            // take up to 58pt and only its own row's bar pays for it.
            Group {
                if let pool {
                    Text(pool).frame(maxWidth: 58, alignment: .leading)
                } else {
                    Text(agent.shortName).frame(width: 38, alignment: .leading)
                }
            }
            .font(CompanionType.font(10))
            .foregroundStyle(CompanionPalette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if let remaining = reading.currentRemainingPercent(now: now) {
                ProgressView(value: Double(remaining), total: 100)
                    .tint(freshness == .stale ? CompanionPalette.ink3
                          : (remaining <= QuotaReading.lowRemainingPercent
                             ? CompanionPalette.status(.requiresInput) : CompanionPalette.accent))
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
        .accessibilityLabel(Text(pool.map { "\(agent.displayName) \($0)" } ?? agent.displayName))
        // A pool row speaks for its own pool; a single row speaks for them all.
        .accessibilityValue(Text(pool == nil ? WatchQuotaVoice.summary(quota, now: now)
                                 : WatchQuotaVoice.line(reading, now: now)))
    }
}
