import SwiftUI
import VibeBuddyKit

/// The four tiles on the inbox home. Each is a slice of the current sessions
/// by presentation state; `all` is the whole current set. Read results have
/// no tile of their own — they are reached through `all`.
enum InboxBucket: String, CaseIterable, Identifiable {
    case all, unreadResults, needsYou, working
    var id: String { rawValue }

    /// The presentation states the bucket admits; `nil` admits every state.
    var states: Set<TaskPresentationState>? {
        switch self {
        case .all: nil
        case .unreadResults: [.completeUnread]
        case .needsYou: [.requiresInput, .error]
        case .working: [.thinking]
        }
    }

    func admits(_ session: AgentSession) -> Bool {
        states?.contains(session.presentationState) ?? true
    }

    /// The tile's word. Under YOLO the third tile usually holds only
    /// confirmed failures, so it says so; a question or approval widens it.
    func title(for summary: TaskPresentationSummary) -> String {
        switch self {
        case .all: String(localized: "All sessions")
        case .unreadResults: String(localized: "Unread results")
        case .needsYou: summary.requiresInput == 0 ? String(localized: "Stuck") : String(localized: "Needs you")
        case .working: String(localized: "Working")
        }
    }

    func count(in summary: TaskPresentationSummary) -> Int {
        switch self {
        case .all: summary.idle + summary.thinking + summary.completeUnread + summary.requiresInput + summary.error
        case .unreadResults: summary.completeUnread
        case .needsYou: summary.needsYou
        case .working: summary.thinking
        }
    }

    var symbol: String {
        switch self {
        case .all: "line.3.horizontal"
        case .unreadResults: "checkmark.circle"
        case .needsYou: "exclamationmark.triangle"
        case .working: "circle.grid.2x2"
        }
    }

    /// The tile glyph's colour: the state colour of what it counts, ink for all.
    func tint(for summary: TaskPresentationSummary) -> Color {
        switch self {
        case .all: CompanionPalette.ink
        case .unreadResults: CompanionPalette.status(.completeUnread)
        case .needsYou: summary.requiresInput == 0 ? CompanionPalette.status(.error) : CompanionPalette.status(.requiresInput)
        case .working: CompanionPalette.status(.thinking)
        }
    }
}

/// Everything the inbox home shows, computed once per snapshot from the
/// current sessions (`SessionCurrency`). Pure: no store, no clock of its own.
struct InboxProjection: Equatable {
    struct ProjectRow: Identifiable, Equatable {
        let project: String
        /// Sessions in this project that are waiting on the person, in
        /// `PendingTasks` order — the number beside the project's name.
        let pendingCount: Int
        let latest: Date
        let label: DashboardProjectLabel
        var id: String { project }
        var title: String {
            project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "No project") : label.title
        }
    }

    let summary: TaskPresentationSummary
    /// The pending queue over every current session, the same order the
    /// detail's "Next" and the Watch's home read.
    let pending: [AgentSession]
    let projects: [ProjectRow]
    /// Current sessions exist in this scope; when false the home shows its
    /// empty state under the agent strip, which stays put so the person can
    /// step back out to the agent that does have something running.
    let hasCurrent: Bool
    /// Any agent has something current — what tells "this one is quiet" apart
    /// from "everything is quiet".
    let fleetHasCurrent: Bool

    var firstUp: AgentSession? { pending.first }
    var pendingCount: Int { pending.count }

    /// `agent` is the strip's choice (ADR-0031): every reading below — the
    /// tiles, the queue, the projects — is that agent's, while the strip above
    /// keeps counting the whole fleet.
    init(sessions: [AgentSession], now: Date, agent: AgentKind? = nil) {
        let fleet = SessionCurrency.current(sessions, now: now)
        fleetHasCurrent = !fleet.isEmpty
        let current = agent.map { kind in fleet.filter { $0.agent == kind } } ?? fleet
        summary = TaskPresentationSummary(sessions: current)
        pending = PendingTasks.ordered(current)
        hasCurrent = !current.isEmpty
        // A project's place mirrors the queue: the project holding the first
        // pending item leads, then the project of the next new one, and so on;
        // projects with nothing pending follow by latest activity.
        var queueRank: [String: Int] = [:]
        for (index, session) in pending.enumerated() {
            let project = session.dashboardProjectIdentity
            if queueRank[project] == nil { queueRank[project] = index }
        }
        let pendingIDs = Set(pending.map(\.id))
        var order: [String] = []
        var byProject: [String: (pending: Int, latest: Date)] = [:]
        for session in current {
            let project = session.dashboardProjectIdentity
            if byProject[project] == nil { order.append(project) }
            var entry = byProject[project] ?? (0, .distantPast)
            if pendingIDs.contains(session.id) { entry.pending += 1 }
            entry.latest = max(entry.latest, session.updatedAt)
            byProject[project] = entry
        }
        let labels = DashboardProjectLabel.labels(for: sessions.map(\.dashboardProjectIdentity))
        projects = order.map {
            ProjectRow(project: $0, pendingCount: byProject[$0]!.pending,
                       latest: byProject[$0]!.latest, label: labels[$0]!)
        }
            .sorted { lhs, rhs in
                switch (queueRank[lhs.project], queueRank[rhs.project]) {
                case let (l?, r?): return l < r
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil):
                    if lhs.latest != rhs.latest { return lhs.latest > rhs.latest }
                    return lhs.project.localizedStandardCompare(rhs.project) == .orderedAscending
                }
            }
    }
}

/// The inbox home (ticket 01, `.scratch/iphone-board`): the title and the
/// snapshot's mood line, the first pending task, the four bucket tiles and
/// the project list. Tapping opens a session's detail or narrows the list;
/// nothing here marks anything read.
struct InboxHomeView: View {
    let projection: InboxProjection
    let now: Date
    /// The agent strip's entries and the allowances they are ringed by; the
    /// strip counts the whole fleet while everything under it is scoped
    /// (ADR-0031).
    let roster: [AgentRoster.Item]
    let quotas: [ProviderQuota]
    @Binding var agent: AgentKind?
    let macName: String
    let statusLine: String
    let hiddenCount: Int
    let openSession: (AgentSession) -> Void
    let openBucket: (InboxBucket) -> Void
    let openProject: (String) -> Void
    let showOlder: () -> Void
    /// "Read pending": the queue above, spoken in order (ticket 04).
    let readPending: () -> Void
    var openRecap: () -> Void = {}
    /// Decisions this phone accepted and is holding until it can reach the
    /// Mac (ADR-0032). Shown above the queue: they are the person's own
    /// unfinished business, and the reason nothing below has moved.
    var held: [QueuedSessionAction] = []
    var retryHeld: () -> Void = {}
    var cancelHeld: (String) -> Void = { _ in }

    @State private var selectedProjectPath: String?

    @Environment(\.dynamicTypeSize) private var typeSize
    /// Two tiles a row, one at accessibility sizes so "Unread results" is
    /// read whole instead of shrinking to a few letters.
    private var tileColumns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 12)]
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inbox")
                    .font(CompanionType.font(30, .semibold))
                    .tracking(CompanionType.tracking(30))
                    .foregroundStyle(CompanionPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: "\(macName) · \(statusLine)")
                    .font(CompanionType.font(13))
                    .foregroundStyle(CompanionPalette.ink2)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            }
            .padding(.horizontal, PhoneMetrics.gutter)
            .padding(.top, 2)
            PhoneAgentStrip(items: roster, quotas: quotas, selection: $agent, now: now)
                .padding(.top, 10)
            if !held.isEmpty {
                heldStrip
                    .padding(.horizontal, PhoneMetrics.gutter)
                    .padding(.top, 12)
            }
            if !projection.hasCurrent {
                // One agent being quiet is not the fleet being quiet, and the
                // strip above is the way back out, so say which one this is.
                PhoneEmptyState(symbol: "moon.zzz",
                                title: agent.map { _ in String(localized: "Nothing running") }
                                    ?? String(localized: "All quiet"),
                                text: quietText) {
                    if let agent, projection.fleetHasCurrent {
                        Button { self.agent = nil } label: {
                            Label("Show all agents", systemImage: "square.grid.2x2")
                        }
                        .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                        .accessibilityHint(Text(verbatim: agent.displayName))
                    } else if hiddenCount > 0 {
                        Button { showOlder() } label: {
                            Label("Show \(hiddenCount) older", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                    }
                }
            } else {
                if let first = projection.firstUp {
                    firstUpRow(first)
                        .padding(.horizontal, PhoneMetrics.gutter)
                        .padding(.top, 14)
                }
                LazyVGrid(columns: tileColumns, spacing: 12) {
                    ForEach(InboxBucket.allCases) { bucket in tile(bucket) }
                }
                .padding(.horizontal, PhoneMetrics.gutter)
                .padding(.top, 12)
                Button(action: openRecap) {
                    Label("Recap", systemImage: "clock.arrow.circlepath")
                        .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PhoneButtonStyle(kind: .quiet))
                .padding(.horizontal, PhoneMetrics.gutter).padding(.top, 14)
                projectList
                    .padding(.top, 18)
            }
        }
        .alert("Project", isPresented: Binding(
            get: { selectedProjectPath != nil },
            set: { if !$0 { selectedProjectPath = nil } }
        ), presenting: selectedProjectPath) { path in
            Button("Copy") { UIPasteboard.general.string = path }
            Button("Cancel", role: .cancel) {}
        } message: { path in
            Text(verbatim: path)
        }
    }

    /// What this phone is holding for the Mac, one row each, with the way
    /// out: try now, or take it back. Never "approved": nothing has landed.
    private var heldStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(held.count == 1
                        ? String(localized: "1 decision waiting to reach \(macName)")
                        : String(localized: "\(held.count) decisions waiting to reach \(macName)"),
                      systemImage: "tray.and.arrow.up")
                    .font(CompanionType.font(13, .semibold))
                    .foregroundStyle(CompanionPalette.status(.requiresInput))
                Spacer(minLength: 8)
                Button("Retry", action: retryHeld)
                    .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                    .accessibilityIdentifier("inbox-held-retry")
            }
            ForEach(held) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.heldLabel(item))
                        .font(CompanionType.font(13))
                        .foregroundStyle(CompanionPalette.ink)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(item.queuedAt, style: .relative)
                        .font(CompanionType.font(11))
                        .foregroundStyle(CompanionPalette.ink3)
                    Button { cancelHeld(item.id) } label: {
                        Image(systemName: "xmark.circle")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CompanionPalette.ink3)
                    .accessibilityLabel(Text("Cancel held decision"))
                }
            }
            if let reason = held.compactMap(\.lastReason).last {
                Text(ConnectionFailureCopy.title(reason, macName: macName))
                    .font(CompanionType.font(11))
                    .foregroundStyle(CompanionPalette.ink2)
            }
        }
        .padding(12)
        .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("inbox-held-decisions")
    }

    static func heldLabel(_ item: QueuedSessionAction) -> String {
        let project = item.project?.isEmpty == false ? item.project! : String(localized: "a task")
        switch item.action {
        case .approval(_, .allow): return String(localized: "Approve · \(project)")
        case .approval(_, .deny): return String(localized: "Deny · \(project)")
        case .answer(_, let text): return String(localized: "Answer · \(project): \(text)")
        case .answerAll: return String(localized: "Answer · \(project)")
        case .stop: return String(localized: "Stop · \(project)")
        }
    }

    /// Why this page is empty: this agent alone, the last day, or nothing yet.
    private var quietText: String {
        if let agent, projection.fleetHasCurrent {
            return String(localized: "\(agent.displayName) has nothing running right now.")
        }
        return hiddenCount > 0
            ? String(localized: "Nothing has moved in the last 24 hours.")
            : String(localized: "Start a Claude Code or Codex session and it'll show up here.")
    }

    /// One line for the head of the pending queue: what it is and where it
    /// sits in the queue. Opens the detail; the read happens there, by rule.
    private func firstUpRow(_ session: AgentSession) -> some View {
        let presentation = RowPresentation(session: session)
        let state = session.presentationState
        return Button { openSession(session) } label: {
            HStack(spacing: 10) {
                StatusDot(state: state, size: PhoneRowMetrics.dot)
                VStack(alignment: .leading, spacing: 2) {
                    // At accessibility sizes the label sits over the title and
                    // both wrap: the item that needs you is never an ellipsis.
                    let firstUpLayout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                    firstUpLayout {
                        Text("First up")
                            .font(CompanionType.font(11, .semibold))
                            .foregroundStyle(CompanionPalette.ink3)
                        Text(session.displayTitle)
                            .font(CompanionType.font(15, .semibold))
                            .foregroundStyle(CompanionPalette.ink)
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    }
                    // The same pair the row shows: what it is, in its colour,
                    // then the question, command or result if there is one.
                    (Text(presentation.activityOrResult).foregroundStyle(CompanionPalette.status(state))
                     + Text(presentation.progress.map { " · " + $0 } ?? "").foregroundStyle(CompanionPalette.ink2))
                        .font(CompanionType.font(12))
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                Spacer(minLength: 6)
                Text(verbatim: "1 / \(projection.pendingCount)")
                    .font(CompanionType.mono(11)).monospacedDigit()
                    .foregroundStyle(CompanionPalette.ink3)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CompanionPalette.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, typeSize.isAccessibilitySize ? 10 : 0)
            .frame(minHeight: 56)
            .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: CompanionType.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: CompanionType.panelRadius)
                .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: [String(localized: "First up"), session.displayTitle, presentation.activityOrResult, presentation.progress ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityHint("Open details")
        .accessibilityIdentifier("phone-inbox-first-up")
    }

    private func tile(_ bucket: InboxBucket) -> some View {
        let count = bucket.count(in: projection.summary)
        let title = bucket.title(for: projection.summary)
        return Button { openBucket(bucket) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: bucket.symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(bucket.tint(for: projection.summary))
                    .frame(height: 24)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(CompanionType.font(16, .semibold))
                        .foregroundStyle(CompanionPalette.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.8)
                    Text(verbatim: "\(count)")
                        .font(CompanionType.font(16, bucket == .all ? .regular : .semibold)).monospacedDigit()
                        .foregroundStyle(bucket == .all ? CompanionPalette.ink3 : bucket.tint(for: projection.summary))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: CompanionType.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: CompanionType.panelRadius)
                .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(title), \(count)"))
        .accessibilityIdentifier("phone-inbox-bucket-\(bucket.rawValue)")
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Projects")
                    .font(CompanionType.font(13, .semibold))
                    .foregroundStyle(CompanionPalette.ink2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if projection.pendingCount > 0 {
                    Button { readPending() } label: {
                        Label("Read pending", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                    .accessibilityIdentifier("phone-inbox-read-pending")
                }
            }
            .padding(.horizontal, PhoneMetrics.gutter)
            .padding(.bottom, 4)
            ForEach(Array(projection.projects.enumerated()), id: \.element.id) { index, row in
                Button { openProject(row.project) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(CompanionPalette.ink3)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(CompanionType.font(16))
                                .foregroundStyle(CompanionPalette.ink)
                                .lineLimit(2)
                            if let parent = row.label.parentPath {
                                Text(parent)
                                    .font(CompanionType.font(12))
                                    .foregroundStyle(CompanionPalette.ink3)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 6)
                        Spacer(minLength: 8)
                        if row.pendingCount > 0 {
                            Text(verbatim: "\(row.pendingCount)")
                                .font(CompanionType.font(14, .medium)).monospacedDigit()
                                .foregroundStyle(CompanionPalette.accentText)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CompanionPalette.ink3)
                    }
                    .padding(.horizontal, PhoneMetrics.gutter)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: row.pendingCount > 0
                    ? "\(row.title), \(String(localized: "\(row.pendingCount) pending"))" : row.title))
                .accessibilityValue(row.project)
                .highPriorityGesture(
                    LongPressGesture().exclusively(before: TapGesture()).onEnded { gesture in
                        switch gesture {
                        case .first: selectedProjectPath = row.project
                        case .second: openProject(row.project)
                        }
                    }
                )
                .accessibilityAction(named: Text("Project")) { selectedProjectPath = row.project }
                .accessibilityIdentifier("phone-inbox-project-\(row.project)")
                if index < projection.projects.count - 1 {
                    PhoneDivider(leading: PhoneMetrics.gutter + 32)
                }
            }
        }
    }
}
