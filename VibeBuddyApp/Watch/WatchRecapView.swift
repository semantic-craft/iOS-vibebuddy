import SwiftUI
import VibeBuddyKit
import WatchKit

/// The recap: what ended since you last read, one page per round, turned
/// with the Digital Crown.
///
/// `TabView(.verticalPage)` is the whole crown story — the system pages,
/// detents and Double Tap come with it, and nothing here focuses, scrubs or
/// listens to the crown itself (ticket 05). Page 1 is the overview, then one
/// page per ended round newest first, then the end page. Opening, turning and
/// leaving send nothing: viewing is viewing (ADR-0021). The Mac composed the
/// recap; the wrist renders it as delivered.
struct WatchRecapView: View {
    @ObservedObject var store: WatchStateStore
    /// Pages are named, not numbered: a round keeps its page when a newer
    /// snapshot reorders or shortens the recap, and a page that disappears
    /// falls back to the overview instead of a tag that no longer exists.
    @State private var page: WatchRecapPage?
    @Environment(\.dismiss) private var dismiss

    init(store: WatchStateStore) {
        self.store = store
        _page = State(initialValue: WatchRecapPage(launchIndex: store.recapInitialPage,
                                                    entries: store.state?.recap?.entries ?? []))
    }

    var body: some View {
        // Demo Mode reads a frozen clock so a launch input always produces the
        // same screen; live relative times age against the real one.
        if store.isDemo {
            content(now: store.launchedAt)
        } else {
            TimelineView(.periodic(from: store.launchedAt, by: 30)) { context in
                content(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let recap = store.state?.recap ?? Recap()
        NavigationStack {
            if recap.entries.isEmpty {
                // The recap emptied while the sheet was open — read on the Mac,
                // or the last round aged out of the day.
                ScrollView {
                    VStack(spacing: 8) {
                        Text("Nothing new since you last read.")
                            .font(CompanionType.font(12))
                            .foregroundStyle(CompanionPalette.ink2)
                            .multilineTextAlignment(.center)
                        Button("Back to dashboard") { dismiss() }
                            .buttonStyle(CompanionButtonStyle(kind: .quiet, size: .wide))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
                .navigationTitle("Recap")
            } else {
                TabView(selection: $page) {
                    WatchRecapOverviewPage(recap: recap, now: now)
                        .tag(Optional(WatchRecapPage.overview))
                    ForEach(Array(recap.entries.enumerated()), id: \.element.id) { index, entry in
                        WatchRecapEntryPage(entry: entry, index: index, count: recap.entries.count, now: now)
                            .tag(Optional(WatchRecapPage.entry(entry.id)))
                    }
                    WatchRecapEndPage(store: store, recap: recap)
                        .tag(Optional(WatchRecapPage.end))
                }
                .tabViewStyle(.verticalPage)
                .navigationTitle("Recap")
                .accessibilityIdentifier("watch-recap-pages")
                .accessibilityLabel(Text("Recap"))
                // A newer snapshot can drop the round under an open page. And a
                // recap that refills after Mark all emptied it is a new recap:
                // it opens on its overview, never on the end page where the
                // previous one's Mark all stood (a tap meant for "Back to
                // dashboard" must not mark rounds nobody has read).
                .onChange(of: recap.entries.map(\.id), initial: true) { before, ids in
                    if case .entry(let id)? = page, !ids.contains(id) { page = .overview }
                    if before.isEmpty, !ids.isEmpty { page = .overview }
                    if page == nil { page = .overview }
                }
            }
        }
    }
}

enum WatchRecapMetrics {
    /// The lane the vertical page indicator rides in on the right edge; page
    /// content stops short of it so a trailing time is never clipped.
    static let indicatorLane: CGFloat = 8
}

/// One page of the recap, by what it shows rather than where it sits.
enum WatchRecapPage: Hashable {
    case overview
    case entry(String)
    case end

    /// Demo Mode's launch input: 0 is the overview, 1…N a round, N+1 the end.
    init(launchIndex: Int, entries: [RecapEntry]) {
        if launchIndex <= 0 {
            self = .overview
        } else if launchIndex > entries.count {
            self = .end
        } else {
            self = .entry(entries[launchIndex - 1].id)
        }
    }
}

// MARK: - Overview

/// The first page: how many, when, and how many went wrong — then the hint
/// that the crown turns the rest.
private struct WatchRecapOverviewPage: View {
    let recap: Recap
    let now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(recap.entries.count) since you last read")
                    .font(CompanionType.font(14, .semibold))
                    .foregroundStyle(CompanionPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                WatchRecapTimeline(entries: recap.entries, now: now)
                if recap.failedCount > 0 {
                    Text("\(recap.failedCount) stopped on an error")
                        .font(CompanionType.font(10))
                        .foregroundStyle(CompanionPalette.status(.error))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    Image(systemName: "digitalcrown.arrow.clockwise")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text("Turn to read")
                        .font(CompanionType.font(10))
                }
                .foregroundStyle(CompanionPalette.ink3)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, WatchRecapMetrics.indicatorLane)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watch-recap-overview")
    }
}

/// A static timeline: "now" on the left, the oldest round on the right, one
/// dot per round at its real time. Decorative — the counts above and the
/// pages after say everything it does, in words.
private struct WatchRecapTimeline: View {
    let entries: [RecapEntry]
    let now: Date

    private var span: TimeInterval {
        max(entries.map { now.timeIntervalSince($0.endedAt) }.max() ?? 60, 60)
    }

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 4
            let width = geo.size.width - inset * 2
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(CompanionPalette.line)
                    .frame(height: CompanionType.hairline)
                    .frame(maxHeight: .infinity, alignment: .center)
                ForEach(entries) { entry in
                    let age = max(0, now.timeIntervalSince(entry.endedAt))
                    Circle()
                        .fill(WatchRecapCopy.dotColor(entry))
                        .frame(width: 5, height: 5)
                        .position(x: inset + CGFloat(age / span) * width, y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 16)
        .overlay(alignment: .bottomLeading) {
            Text("now").font(CompanionType.font(8)).foregroundStyle(CompanionPalette.ink3)
                .offset(y: 10)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(WatchFormat.duration(span)).font(CompanionType.font(8)).monospacedDigit()
                .foregroundStyle(CompanionPalette.ink3)
                .offset(y: 10)
        }
        .padding(.bottom, 10)
        .accessibilityHidden(true)
    }
}

// MARK: - One round

/// One ended round: whose and when, what it was, and the points the Mac
/// kept. Scrolls within the page at large text sizes; the crown pages when
/// the page has nothing left to scroll, so the page carries no spare room
/// below its content.
private struct WatchRecapEntryPage: View {
    let entry: RecapEntry
    let index: Int
    let count: Int
    let now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(WatchRecapCopy.dotColor(entry))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text("\(entry.agent.shortName) · \(entry.project)")
                        .font(CompanionType.font(10))
                        .foregroundStyle(CompanionPalette.ink2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    Text(WatchRecapCopy.ago(entry.endedAt, now: now))
                        .font(CompanionType.font(10))
                        .monospacedDigit()
                        .foregroundStyle(CompanionPalette.ink3)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(WatchRecapCopy.headerLabel(entry, now: now)))
                Text(entry.title)
                    .font(CompanionType.font(14, .semibold))
                    .foregroundStyle(CompanionPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                CompanionHairline()
                ForEach(Array(entry.points.enumerated()), id: \.offset) { _, point in
                    bullet(point, color: CompanionPalette.ink2)
                }
                if entry.kind == .failed {
                    // The outcome line is the wrist's own words for the kind;
                    // the Mac sends the summary and the edit volume only.
                    bullet(String(localized: "Stopped with an error"), color: CompanionPalette.status(.error))
                }
                Text("\(index + 1) of \(count)")
                    .font(CompanionType.font(9))
                    .monospacedDigit()
                    .foregroundStyle(CompanionPalette.ink3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, WatchRecapMetrics.indicatorLane)
        }
        .accessibilityIdentifier("watch-recap-entry-\(index + 1)")
    }

    private func bullet(_ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle()
                .fill(CompanionPalette.ink3)
                .frame(width: 3, height: 3)
                .accessibilityHidden(true)
            Text(text)
                .font(CompanionType.font(11))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - End

/// The last page: where the recap stops, and the one action. Mark all is
/// explicit confirmation in bulk — the Mac's horizon moves to the newest round
/// shown and every completed round shown is read — with one local `.success`
/// tap and no confirmation page. The button becomes a status line as soon as
/// the intent is queued; the recap itself changes only when a snapshot says
/// the Mac moved on (ADR-0021).
private struct WatchRecapEndPage: View {
    @ObservedObject var store: WatchStateStore
    let recap: Recap

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(WatchRecapCopy.endLine(recap))
                    .font(CompanionType.font(12))
                    .foregroundStyle(CompanionPalette.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let phase = store.recapMarkPhase(for: recap) {
                    WatchRecapStatusLine(phase: phase)
                        .accessibilityIdentifier("watch-recap-marked")
                } else if store.state?.sourceID != nil, store.state?.pairingEpoch != nil {
                    Button("Mark all") {
                        WKInterfaceDevice.current().play(.success)
                        store.markRecapRead(recap)
                    }
                    .buttonStyle(CompanionButtonStyle(kind: .quiet, size: .wide))
                    .handGestureShortcut(.primaryAction)
                    .accessibilityIdentifier("watch-recap-mark-all")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.trailing, WatchRecapMetrics.indicatorLane)
        }
        .accessibilityIdentifier("watch-recap-end")
    }
}

/// What the wrist may say about a Mark all in flight, in the grammar of
/// `WatchAnswerStatusLine`: sending, taken, queued for later, or not delivered.
enum WatchRecapMarkPhase: Equatable {
    case sending, accepted, queued, failed
}

private struct WatchRecapStatusLine: View {
    let phase: WatchRecapMarkPhase

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if phase == .sending { ProgressView().controlSize(.mini) }
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Never "Read": the wrist knows the Mac took it; the recap goes away when
    /// a later snapshot says so.
    private var message: LocalizedStringResource {
        switch phase {
        case .sending: return "Sending…"
        case .accepted: return "Sent. Waiting for your Mac to confirm."
        case .queued: return "Marked · syncs when connected"
        case .failed: return "Couldn't send that. Will retry."
        }
    }
}

// MARK: - Copy

/// The recap's sentences, in one place: the home row, the relative time,
/// the end line. Every string is a localized template, never assembled from
/// a literal and a suffix.
enum WatchRecapCopy {
    /// "12m ago" — the same short duration the rest of the wrist uses.
    static func ago(_ date: Date, now: Date) -> String {
        String(localized: "\(WatchFormat.duration(now.timeIntervalSince(date))) ago")
    }

    /// The home row's second line: "1 failed · newest 12m ago", or just the
    /// freshness when nothing failed. Entries arrive newest first.
    static func rowDetail(_ recap: Recap, now: Date) -> String? {
        guard let newest = recap.entries.first else { return nil }
        var parts: [String] = []
        if recap.failedCount > 0 {
            parts.append(String(localized: "\(recap.failedCount) failed"))
        }
        parts.append(String(localized: "newest \(ago(newest.endedAt, now: now))"))
        return parts.joined(separator: " · ")
    }

    /// The end page's sentence. A horizon is a moment the wearer set; without
    /// one the recap is bounded by the day alone.
    static func endLine(_ recap: Recap) -> String {
        guard let horizon = recap.horizon else {
            return String(localized: "That's everything from the last 24 hours")
        }
        let stamp = Calendar.current.isDateInToday(horizon)
            ? horizon.formatted(date: .omitted, time: .shortened)
            : horizon.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return String(localized: "That's everything since \(stamp)")
    }

    /// The round's dot: completed and unread in the results colour, failed in
    /// the error colour, already read in tertiary ink.
    static func dotColor(_ entry: RecapEntry) -> Color {
        switch entry.kind {
        case .failed: return CompanionPalette.status(.error)
        case .completed: return entry.isRead ? CompanionPalette.ink3 : CompanionPalette.status(.completeUnread)
        }
    }

    /// What VoiceOver says for the header line, since the dot is colour alone.
    static func headerLabel(_ entry: RecapEntry, now: Date) -> String {
        let state: String
        switch entry.kind {
        case .failed: state = String(localized: "Error")
        case .completed: state = entry.isRead ? String(localized: "Read") : String(localized: "Done, unread")
        }
        return "\(state), \(entry.agent.shortName) · \(entry.project), \(ago(entry.endedAt, now: now))"
    }
}
