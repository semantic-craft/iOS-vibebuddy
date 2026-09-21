import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// The dashboard's library tabs, and the one programmatic way to land on one
/// of them from elsewhere. Settings › Plan & quota uses it to open the Usage
/// page rather than repeat its readings (ADR-0017 §6). `@Published` replays
/// the current value to a new subscriber, so a request made before the
/// dashboard window has ever been built still reaches the view once it is.
@MainActor
final class DashboardRoute: ObservableObject {
    enum Library: String { case inbox, recap, live, history, favorites, usage }

    static let shared = DashboardRoute()
    enum Destination { case library(Library), session(String), firstPending, nextPending }
    @Published fileprivate var requested: Destination?

    static func open(_ library: Library) {
        shared.requested = .library(library)
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }

    static func openSession(id: String) {
        shared.requested = .session(id)
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }

    static func openNextPending() {
        shared.requested = .nextPending
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }

    static func openFirstPending() {
        shared.requested = .firstPending
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }
}

/// Project navigation, the filtered session list, and the existing live detail
/// surface. These filters never alter the shared snapshot or Buddy scope.
struct DashboardView: View {
    @ObservedObject var model: MenuBarModel
    @State private var pendingNavigation = PendingTaskNavigation()
    @State private var statusFilter: DashboardSessionList.StatusFilter? = nil
    @State private var projectScope: DashboardSessionList.ProjectScope = .all
    @State private var query: String = ""
    @State private var showNewTask = false
    /// What Continue with… put into the New task sheet; nil for a plain ⌘N.
    @State private var newTaskPrefill: NewTaskPrefill?
    @State private var showSpeechPanel = false
    @State private var libraryScope = "inbox"
    @State private var showOlder = false
    /// History and Favorites filter by project path; the sidebar owns the
    /// choice so both libraries share one project list.
    @State private var historyProject: String?
    @State private var agentFilter: AgentKind?
    @StateObject private var history: HistoryLibraryModel
    /// One reader for both libraries, so the transcript file watcher and the
    /// in-flight read follow the selection rather than the library tab.
    @StateObject private var reader: SessionReaderModel
    // Demo instance pre-selects the approval session so the detail pane (diff +
    // Approve/Deny) is shown for screenshots; nil in normal use.
    // `VIBEBUDDY_DEMO_SELECT=<demo session id>` picks another row for
    // screenshots of the done / working readings.
    @State private var selection: String? =
        ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1"
            ? (ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO_SELECT"] ?? "demo-edit") : nil
    @FocusState private var searchFocused: Bool
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false
    /// Composer drafts by session id, for this window's lifetime: a draft
    /// survives opening, expanding or closing a tool and the narrow-window
    /// pane (which all rebuild the reading column), and a selection change
    /// shows the other session's own draft, never this one.
    @State private var composerDrafts: [String: String] = [:]
    /// The sidebar's two settled shapes, remembered like the quota plinth:
    /// its last labeled width and whether it is folded to the icon rail.
    /// `DashboardSidebarWidth` holds the bounds and the snap rule.
    @AppStorage("dashboard.sidebarLabeledWidth") private var sidebarLabeledWidth = Double(DashboardSidebarWidth.labeledDefault)
    @AppStorage("dashboard.sidebarIconOnly") private var sidebarIconOnly = false
    /// The pointer's width while a drag on the sidebar's edge is live; nil at rest.
    @State private var sidebarDragWidth: CGFloat?
    @State private var sidebarDragOrigin: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sidebarSettledWidth: CGFloat {
        sidebarIconOnly ? DashboardSidebarWidth.iconOnly : DashboardSidebarWidth.clampedLabeled(CGFloat(sidebarLabeledWidth))
    }
    private var sidebarWidth: CGFloat { sidebarDragWidth ?? sidebarSettledWidth }
    /// Release and the double-click settle with a short snappy spring; with
    /// Reduce Motion on, the width just changes.
    private var sidebarSettle: Animation? { reduceMotion ? nil : .snappy }

    private func sidebarDragBegan() {
        sidebarDragOrigin = sidebarSettledWidth
        var live = Transaction()
        live.disablesAnimations = true
        withTransaction(live) { sidebarDragWidth = sidebarSettledWidth }
    }

    /// Follow the pointer inside the hard bounds; no snap, no rubber-band.
    private func sidebarDragChanged(by delta: CGFloat) {
        var live = Transaction()
        live.disablesAnimations = true
        withTransaction(live) { sidebarDragWidth = DashboardSidebarWidth.clampedDuringDrag(sidebarDragOrigin + delta) }
    }

    private func sidebarDragEnded() {
        guard let released = sidebarDragWidth else { return }
        let target = DashboardSidebarWidth.settled(released: released)
        withAnimation(sidebarSettle) {
            sidebarIconOnly = target == DashboardSidebarWidth.iconOnly
            if !sidebarIconOnly { sidebarLabeledWidth = Double(target) }
            sidebarDragWidth = nil
        }
    }

    private func sidebarToggleIconOnly() {
        withAnimation(sidebarSettle) { sidebarIconOnly.toggle() }
    }

    /// One accessibility increment or decrement: a step through the labeled
    /// range, folding to the rail below the narrowest labeled width and
    /// unfolding from it.
    private func sidebarStep(_ direction: Int) {
        withAnimation(sidebarSettle) {
            if sidebarIconOnly {
                if direction > 0 { sidebarIconOnly = false }  // back to the remembered labeled width
                return
            }
            let current = DashboardSidebarWidth.clampedLabeled(CGFloat(sidebarLabeledWidth))
            if direction < 0, current <= DashboardSidebarWidth.minLabeled { sidebarIconOnly = true; return }
            let stepped = current + CGFloat(direction) * DashboardSidebarWidth.accessibilityStep
            sidebarLabeledWidth = Double(DashboardSidebarWidth.clampedLabeled(stepped))
        }
    }

    private var sidebarAccessibilityValue: String {
        sidebarIconOnly ? String(localized: "Icons only")
            : String(localized: "Labeled, \(Int(sidebarSettledWidth.rounded())) points")
    }

    private func draftBinding(for sessionID: String) -> Binding<String> {
        let key = (model.completionSourceID ?? "unknown") + "/" + sessionID
        return Binding(get: { composerDrafts[key] ?? "" },
                       set: { composerDrafts[key] = $0.isEmpty ? nil : $0 })
    }

    init(model: MenuBarModel) {
        self.model = model
        let history = HistoryLibraryModel()
        _history = StateObject(wrappedValue: history)
        _reader = StateObject(wrappedValue: SessionReaderModel(history: history, model: model))
    }

    private var projection: DashboardSessionList {
        DashboardSessionList(model.sessions, project: projectScope, status: statusFilter,
                             agent: agentFilter, query: query, selection: selection, showOlder: showOlder,
                             recentDirectories: model.recentDirectories)
    }
    private func subject(for session: AgentSession) -> ReaderSubject {
        let record = SessionReaderSource.recordID(for: session).flatMap { id in history.snapshot.sessions.first { $0.id == id } }
        return ReaderSubject(origin: .live, live: session, record: record)
    }

    private var filtered: [AgentSession] { projection.visible }
    private var selectedSession: AgentSession? { projection.selected }

    private func projectTitle(_ scope: DashboardSessionList.ProjectScope) -> String {
        DashboardSidebar.title(scope)
    }

    /// The search field lives in the live and history list heads; Usage has
    /// none, so searching from there lands on Current tasks.
    private func focusSearch() {
        if libraryScope == "usage" || libraryScope == "inbox" || libraryScope == "recap" { openBucket(nil) }
        searchFocused = true
    }

    /// History's projects with a conversation count each, for the sidebar.
    private var historyProjects: [(path: String, count: Int)] {
        let counts = Dictionary(grouping: history.snapshot.sessions, by: \.projectPath).mapValues(\.count)
        return counts.keys.sorted().map { (path: $0, count: counts[$0] ?? 0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            DashboardSidebar(model: model, voice: model.voiceChat, library: $libraryScope,
                             projectScope: $projectScope, historyProject: $historyProject,
                             liveProjects: projection.projects, historyProjects: historyProjects,
                             onNewTask: { showNewTask = true },
                             onSearch: focusSearch,
                             onOpenSpeech: { showSpeechPanel = true }, speechPanelPresented: showSpeechPanel,
                             onOpenProject: { scope in
                                 if libraryScope == "inbox" { openBucket(nil) }
                                 projectScope = scope
                                 libraryScope = "live"
                             },
                             width: sidebarWidth)
            Rectangle().fill(MacTheme.line).frame(width: CompanionType.hairline)
                // The drag handle straddles the hairline; it draws above the
                // content column so its pill and tip are never covered.
                .overlay {
                    SidebarResizeHandle(dragging: sidebarDragWidth != nil, accessibilityValue: sidebarAccessibilityValue,
                                        onDragBegan: sidebarDragBegan,
                                        onDragChanged: sidebarDragChanged,
                                        onDragEnded: sidebarDragEnded,
                                        onDoubleClick: sidebarToggleIconOnly,
                                        onStep: sidebarStep)
                }
                .zIndex(1)
            Group {
                if libraryScope == "inbox" {
                    MacInboxHomeView(model: model, projection: projection, recap: model.recap,
                                     openRecap: { libraryScope = "recap" },
                                     readPending: { model.readPending(); showSpeechPanel = true },
                                     openFirst: openFirstPending,
                                     openBucket: openBucket,
                                     openProject: { projectScope = $0; statusFilter = nil; query = ""; showOlder = false; libraryScope = "live" },
                                     openOlder: { openBucket(nil); showOlder = true })
                } else if libraryScope == "recap" {
                    MacRecapView(model: model)
                } else if libraryScope == "live" {
                    HSplitView {
                        sessionsColumn
                        detailColumn
                    }
                } else if libraryScope == "usage" {
                    UsageWorkbenchView(model: model)
                } else {
                    HistoryWorkbenchView(history: history, model: model, reader: reader, query: $query,
                                         favoritesOnly: libraryScope == "favorites",
                                         project: $historyProject, searchFocused: $searchFocused)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MacTheme.bg)
        // Same tint as Settings, so system controls here pick up the buddy's green.
        .tint(MacTheme.accent)
        .onReceive(DashboardRoute.shared.$requested) { destination in
            guard let destination else { return }
            switch destination {
            case .library(let library): libraryScope = library.rawValue
            case .session(let id):
                openBucket(nil)
                selection = id
                if let session = model.sessions.first(where: { $0.id == id }) { selectSession(session) }
            case .firstPending: openFirstPending()
            case .nextPending: openGlobalNext()
            }
            // Clear on the next turn so the request is consumed once and the
            // publisher is not re-entered from inside its own delivery.
            DispatchQueue.main.async { DashboardRoute.shared.requested = nil }
        }
        .sheet(isPresented: $showNewTask, onDismiss: { newTaskPrefill = nil }) { NewTaskSheet(model: model, prefill: newTaskPrefill) }
        .onChange(of: model.continueRequest) { _, request in presentContinue(request) }
        .sheet(isPresented: $showSpeechPanel) { MacVoicePanel(model: model) }
        .onAppear {
            // `VIBEBUDDY_DEMO_PAGE=dashboard/<live|history|favorites|usage|newtask>`
            // lands on that library, or opens New task, for screenshots and QA.
            guard let page = ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO_PAGE"],
                  page.hasPrefix("dashboard/") else { return }
            let target = String(page.dropFirst("dashboard/".count))
            if target == "newtask" { showNewTask = true } else if let library = DashboardRoute.Library(rawValue: target) {
                libraryScope = library.rawValue
            } else if target.hasPrefix("continue:") {
                // `dashboard/continue:<session id>:<agent raw value>` opens Continue
                // with… for that session once it is listed — the isolated QA
                // instance has no pointer and no launcher of its own.
                let parts = target.dropFirst("continue:".count).split(separator: ":", maxSplits: 1).map(String.init)
                guard let id = parts.first, let agent = parts.count > 1 ? AgentKind(rawValue: parts[1]) : .claudeCode else { return }
                Task { @MainActor in
                    // Wait for the row, then one more poll so the snapshot that
                    // named its checkout (and scanned its handoffs) has landed.
                    var ready: AgentSession?
                    for _ in 0..<120 {
                        if let session = model.sessions.first(where: { $0.id == id }), session.checkoutPath != nil {
                            if ready != nil { break }
                            ready = session
                        }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                    }
                    guard let session = model.sessions.first(where: { $0.id == id }) ?? ready else { return }
                    selection = id
                    model.requestContinue(session, with: agent)
                }
            }
        }
        .background {
            Group {
                // ⌘N opens New task; the sheet itself explains when no agent
                // can start yet, so the entry is never disabled.
                Button("") { showNewTask = true }.keyboardShortcut("n", modifiers: .command)
                Button("") { openBucket(.needsYou) }.keyboardShortcut("1", modifiers: .command)
                Button("") { openBucket(.working) }.keyboardShortcut("2", modifiers: .command)
                Button("") { openBucket(.done) }.keyboardShortcut("3", modifiers: .command)
                Button("") { openBucket(.idle) }.keyboardShortcut("4", modifiers: .command)
                Button("") { openBucket(nil) }.keyboardShortcut("0", modifiers: .command)
                // ⌘F focuses the search field, leaving Usage first if needed.
                Button("", action: focusSearch).keyboardShortcut("f", modifiers: .command)
                // ⏎ jumps to the selected session's terminal. Ignored while typing in
                // search so it doesn't shadow the field's own Return.
                Button("") {
                    // Text editors (including detail composers/questions) own
                    // Return while editing; a selected row must not steal it.
                    if libraryScope == "live", !searchFocused, !(NSApp.keyWindow?.firstResponder is NSTextView),
                       let s = selectedSession { model.jump(s) }
                }
                    .keyboardShortcut(.return, modifiers: [])
            }
            .opacity(0)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("vibebuddy.selectNextPending"))) { _ in
            openGlobalNext()
        }
        .onDisappear { model.dashboardViewedSessionID = nil }
        .task { await history.observeHistory() }
        .onChange(of: projectScope) { _, scope in
            resetTour()
            switch scope {
            case .all, .unknown: historyProject = nil
            case .project(let path):
                if historyProjects.contains(where: { $0.path == path }) { historyProject = path }
                else if !path.hasPrefix("/") {
                    let matches = historyProjects.map(\.path).filter { URL(fileURLWithPath: $0).lastPathComponent == path }
                    historyProject = matches.count == 1 ? matches[0] : nil
                } else { historyProject = nil }
            }
        }
        .onChange(of: historyProject) { _, path in
            guard libraryScope != "live" else { return }
            projectScope = path.map { .project($0) } ?? .all
        }
        .onChange(of: agentFilter) { _, _ in resetTour() }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if selection == nil, let wanted = ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO_SELECT"], ids.contains(wanted) {
                selection = wanted
            }
        }
        .onChange(of: statusFilter) { _, _ in resetTour() }
        .onChange(of: query) { _, _ in resetTour() }
        .onChange(of: showOlder) { _, _ in resetTour() }
        .onChange(of: model.completionSourceID) { old, _ in
            resetTour()
            if old != nil { selection = nil }
        }
    }

    private func openGlobalNext() {
            // The global hotkey declares a global route. The detail footer's
            // Next uses the selected scope and never posts this notification.
            let current = selectedSession
            if projectScope != .all || statusFilter != nil || !query.isEmpty || showOlder || agentFilter != nil { openBucket(nil) }
            libraryScope = "live"
            if let next = pendingNavigation.next(in: projection.globalPending, after: current) { selection = next.id }
    }

    private func resetTour() {
        pendingNavigation = PendingTaskNavigation()
        if let current = selectedSession { pendingNavigation.select(current, in: projection.pending) }
    }

    private func openBucket(_ filter: DashboardSessionList.StatusFilter?) {
        libraryScope = "live"
        projectScope = .all
        statusFilter = filter
        agentFilter = nil
        query = ""
        showOlder = false
        resetTour()
    }

    private func openFirstPending() {
        openBucket(nil)
        if let first = projection.globalPending.first { selectSession(first) }
        else { selection = nil }
    }

    private func selectSession(_ session: AgentSession) {
        pendingNavigation.select(session, in: projection.pending)
        selection = session.id
    }

    private var scopeTitle: String {
        var parts = [projectScope == .all ? String(localized: "All sessions") : projectTitle(projectScope)]
        if let statusFilter { parts.append(String(localized: String.LocalizationValue(Self.chipTitleKey(statusFilter)))) }
        if let agentFilter { parts.append(agentFilter.displayName) }
        if !query.isEmpty { parts.append(String(localized: "Search: \(query)")) }
        if showOlder { parts.append(String(localized: "Including older")) }
        return parts.joined(separator: " · ")
    }

    private var pendingFooter: some View {
        let queue = projection.pending
        let index = queue.firstIndex { $0.id == selection }
        let hasNext = queue.contains { $0.id != selection }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(scopeTitle).lineLimit(2)
                Spacer(minLength: 8)
                Button("Next pending") {
                    if let next = pendingNavigation.next(in: queue, after: selectedSession) { selection = next.id }
                }
                .buttonStyle(.borderless)
                .disabled(!hasNext)
                .accessibilityIdentifier("mac-dashboard-next-pending")
            }
            if let index {
                Text("\(index + 1) / \(queue.count)")
            } else if selection != nil, selectedSession == nil {
                Text("Session unavailable")
            } else if selectedSession?.presentationState == .idle {
                Text("Current item handled · \(queue.count) remaining")
            } else if selection != nil {
                Text("Current item is outside pending · \(queue.count) remaining")
            }
            if !hasNext {
                Text(statusFilter == .working ? "Working sessions have no pending results in this scope." : "No other pending tasks in this scope.")
            }
        }
        .font(MacTheme.font(10.5)).foregroundStyle(MacTheme.ink2)
        .padding(12)
        .background(MacTheme.bg2)
    }

    /// The list column's head, as Cursor lays out a list page: the scope as
    /// the title, the search field, then a row of filter chips. ⌘1–5 and ⌘0
    /// still drive the same filter.
    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(scopeTitle).font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(filtered.count == 1 ? String(localized: "1 session") : String(localized: "\(filtered.count) sessions"))
                        .font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                }
                SearchPill(query: $query, focused: $searchFocused)
                if projection.olderCount > 0 || showOlder {
                    Toggle(isOn: $showOlder) { Text("Show \(projection.olderCount) older") }
                        .toggleStyle(.checkbox).font(MacTheme.font(10.5))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        MenuPill(title: agentFilter.map(\.displayName) ?? String(localized: "All agents"),
                                 emphasized: agentFilter != nil) {
                            Button("All agents") { agentFilter = nil }
                            ForEach(projection.agents, id: \.self) { agent in
                                Button(agent.displayName) { agentFilter = agent }
                            }
                        }
                        .accessibilityLabel("Filter sessions by agent")
                        FilterChip(title: "All", selected: statusFilter == nil) { statusFilter = nil }
                        ForEach(DashboardSessionList.StatusFilter.allCases, id: \.self) { group in
                            FilterChip(title: Self.chipTitle(group), selected: statusFilter == group) { statusFilter = group }
                        }
                        if projectScope != .all || !query.isEmpty || agentFilter != nil {
                            Button("Reset") {
                                projectScope = .all
                                statusFilter = nil
                                agentFilter = nil
                                query = ""
                            }
                            .buttonStyle(.plain).font(MacTheme.font(10.5)).foregroundStyle(MacTheme.ink3)
                        }
                    }
                }
                .accessibilityLabel("Filter sessions by state")
            }
            .padding(.horizontal, 12).padding(.top, 12)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if filtered.isEmpty {
                        QuietEmptyState(title: model.sessions.isEmpty ? "No sessions reporting" : "No matching sessions",
                                        message: model.sessions.isEmpty
                                            ? "Start a Claude Code or Codex turn. If nothing appears, repair hooks in Settings."
                                            : "Clear a filter or try another search.",
                                        systemName: "waveform.path.ecg")
                            .padding(.top, 40)
                    } else {
                        ForEach(filtered) { session in
                            SummaryRow(session: session, isSelected: selection == session.id,
                                       included: model.buddySessionIDs.contains(session.id), showInclude: companionEnabled,
                                       handoffReady: ContinueWith.handoff(for: session, in: model.handoffs) != nil,
                                       continues: continuesLabel(for: session),
                                       onSelect: { selectSession(session) },
                                       onToggleInclude: { model.toggleBuddy(session.id) })
                                .contextMenu {
                                    AttentionPicker(session: session, model: model, style: .menu)
                                    if session.status == .done, session.completionID != nil {
                                        Button(session.hasUnreadCompletion ? "Mark as read" : "Mark as unread") {
                                            if session.hasUnreadCompletion { model.acknowledge(session.id, displayedCompletionID: session.completionID) }
                                            else { model.markUnread(session) }
                                        }
                                    }
                                    ContinueWithMenu(session: session, model: model)
                                }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
    }

    /// Continue with… asked for the sheet: prefill it and consume the request.
    private func presentContinue(_ request: NewTaskPrefill?) {
        guard let request else { return }
        newTaskPrefill = request
        showNewTask = true
        model.continueRequest = nil
    }

    /// "continues Codex · title" for a session the Mac started from another
    /// one; the source's title when it is still listed, its key otherwise.
    private func continuesLabel(for session: AgentSession) -> String? {
        guard let key = session.continuesSessionKey else { return nil }
        let nativeID = key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
        if let source = model.sessions.first(where: { $0.id == nativeID }) {
            return String(localized: "continues \(source.agent.displayName) · \(source.displayTitle)")
        }
        return String(localized: "continues \(key)")
    }

    /// The chips use the menu panel's group words (Needs you / Working / Done),
    /// not the long state labels, so all five fit on one line. Errors are part
    /// of Needs you here as everywhere else.
    static func chipTitle(_ group: DashboardSessionList.StatusFilter) -> LocalizedStringKey {
        LocalizedStringKey(chipTitleKey(group))
    }

    static func chipTitleKey(_ group: DashboardSessionList.StatusFilter) -> String {
        switch group {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Unread results"
        case .idle: "Idle"
        }
    }

    @ViewBuilder private var detailColumn: some View {
        if let s = selectedSession {
            VStack(spacing: 0) {
                SessionReaderPane(subject: subject(for: s), targetMessage: nil, model: model, history: history, reader: reader, draft: draftBinding(for: s.id))
                pendingFooter
            }
                .frame(minWidth: 340, idealWidth: 520, maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                QuietEmptyState(title: selection == nil ? "Select a session" : "Session unavailable",
                                message: selection == nil ? "Pick a task on the left to see its details." : "This session is no longer available. Choose another task.")
                pendingFooter
            }
                .frame(minWidth: 340, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

struct SearchPill: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold)).foregroundStyle(MacTheme.ink3)
            TextField("Search sessions", text: $query)
                .textFieldStyle(.plain)
                .font(MacTheme.font(12, .semibold))
                .focused(focused)
            if query.isEmpty {
                Text("⌘F").font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
            } else {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MacTheme.ink3) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 28)
        .companionCard(radius: 14)
    }
}

/// A selectable task and an independent Buddy-scope control. Toggling Buddy
/// must not implicitly select or acknowledge the row.
private struct SummaryRow: View {
    let session: AgentSession
    var isSelected = false
    var included = false
    var showInclude = false
    /// A handoff document names this session as its source (ADR-0023).
    var handoffReady = false
    /// Which session this one was started to continue, if any.
    var continues: String?
    var onSelect: () -> Void
    var onToggleInclude: () -> Void

    private var presentation: RowPresentation { RowPresentation(session: session) }
    private var state: TaskPresentationState { session.presentationState }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    AgentTile(agent: session.agent, state: state, ground: isSelected ? MacTheme.bg2 : MacTheme.bg3)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.displayTitle).font(MacTheme.font(13, .medium))
                            .foregroundStyle(MacTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(presentation.activityOrResult)
                            .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.status(state))
                            .lineLimit(2)
                        if let progress = presentation.progress {
                            Text(progress).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                                .lineLimit(2).help(progress)
                        }
                        HStack(spacing: 6) {
                            Text(session.project).lineLimit(1).truncationMode(.middle)
                                .help(session.agent.displayName + " · " + session.project)
                            Spacer(minLength: 0)
                            if handoffReady {
                                Text("Handoff ready").foregroundStyle(MacTheme.accent)
                                    .help("A handoff document names this session. Continue with… starts another agent from it.")
                                    .accessibilityIdentifier("handoff-ready")
                            }
                            if presentation.unread { Text("Unread").foregroundStyle(MacTheme.status(.completeUnread)) }
                            if let glyph = session.effectiveAttention.rowGlyph {
                                Image(systemName: glyph).help(session.effectiveAttention.title)
                            }
                            Text(presentation.updatedAt, style: .relative).monospacedDigit()
                    }
                    .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    if let warning = presentation.observationWarning {
                        Text(warning)
                        if let seen = presentation.lastObservedAt {
                            Text("Last observed: \(seen.formatted())")
                        }
                    }
                    if let continues { Text(continues).lineLimit(1).truncationMode(.middle).help(continues) }
                    if let stats = session.ledgerSummary { Text(stats).lineLimit(2) }
                    if let child = ToolActivity.childSummary(for: session) { Text(child) }
                    }
                    .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if showInclude {
                Button(action: onToggleInclude) {
                    Image(systemName: included ? "waveform.circle.fill" : "waveform.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(included ? MacTheme.accent : MacTheme.ink2)
                .accessibilityLabel(included ? "Remove from the buddy's context" : "Add to the buddy's context")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard(isSelected ? MacTheme.bg2 : MacTheme.bg3)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                    .strokeBorder(MacTheme.accent.opacity(0.6), lineWidth: CompanionType.hairline)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The row's leading mark: the agent's product tile so the eye can tell a
/// Claude row from a Codex row without reading, with the task state as a
/// small dot on the tile's bottom-right corner. The dot's ring is the row's
/// own ground so it reads as sitting on the card, not stuck onto the tile.
private struct AgentTile: View {
    let agent: AgentKind
    let state: TaskPresentationState
    let ground: Color

    var body: some View {
        AgentAvatar(agent: agent, size: 28)
            .overlay(alignment: .bottomTrailing) {
                StateGlyph(state: state, size: 12)
                    .padding(1.5)
                    .background(ground, in: Circle())
                    .offset(x: 4, y: 4)
            }
            .accessibilityElement(children: .combine)
    }
}

struct VoiceConsentSheet: View {
    @ObservedObject var voice: VoiceChat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Voice companion", systemImage: "waveform").font(MacTheme.font(13, .semibold))
            Text("Tap the buddy to talk — it knows your sessions and can approve / answer for you. Pick the provider whose key you've filled in below. Switching applies instantly if the buddy is already listening.")
                .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Enabling opens the mic on the next tap and shares your live sessions with your selected provider, using your own key.")
                .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
                Button("Enable") { voice.enableCompanion(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent), size: .small))
            }
        }
        .padding(20).frame(width: 380)
    }
}

/// One line of free text for a session, sent with ⌘↩ or the button.
struct InstructionComposer: View {
    let placeholder: String
    /// A draft owned outside the composer (the dashboard keeps one per
    /// session, so it survives the reading column being rebuilt and never
    /// follows a selection change); `nil` keeps a private one.
    var externalDraft: Binding<String>? = nil
    let send: (String) -> Void
    @State private var localDraft = ""
    private var draft: Binding<String> { externalDraft ?? $localDraft }

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(MacTheme.font(13, .semibold))
                .lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(MacTheme.bg2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onSubmit(submit)
            Button("Send", action: submit)
                .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent)))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit() {
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(text)
        draft.wrappedValue = ""
    }
}

/// The one control for how much a session may interrupt you, in two shapes:
/// a row of filter chips in the detail pane (the list head's chips, so the
/// card carries no system segmented control) and radio items in a row's
/// context menu. `nil` is "automatic" — the daemon's own reading of recent
/// interaction.
struct AttentionPicker: View {
    enum Style { case chips, menu }
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    let style: Style

    private var selection: Binding<SessionAttention?> {
        Binding(get: { session.attentionOverride },
                set: { model.setAttention(session.id, $0) })
    }

    var body: some View {
        switch style {
        case .chips: chips
        case .menu: picker.pickerStyle(.inline)
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            FilterChip(title: "Auto", selected: session.attentionOverride == nil) { selection.wrappedValue = nil }
            ForEach(SessionAttention.allCases, id: \.self) { level in
                FilterChip(title: LocalizedStringKey(level.titleKey), selected: session.attentionOverride == level) {
                    selection.wrappedValue = level
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
    }

    private var picker: some View {
        Picker("Notifications", selection: selection) {
            Text("Automatic (\(autoLevel.title.lowercased()))").tag(SessionAttention?.none)
            ForEach(SessionAttention.allCases, id: \.self) { level in
                Label(level.title, systemImage: level.symbol).tag(SessionAttention?.some(level))
            }
        }
        .labelsHidden()
    }

    /// What automatic would give right now: the effective level while no
    /// override is set, else the daemon's `attention` still reflects the
    /// override, so fall back to `normal` as the honest default.
    private var autoLevel: SessionAttention {
        session.attentionOverride == nil ? session.effectiveAttention : .normal
    }
}

extension SessionAttention {
    /// The English key; `title` is its localized form.
    var titleKey: String {
        switch self {
        case .followed: "Followed"
        case .normal: "Normal"
        case .muted: "Muted"
        }
    }
    var title: String { String(localized: String.LocalizationValue(titleKey)) }
    var symbol: String {
        switch self {
        case .followed: "bell.badge"
        case .normal: "bell"
        case .muted: "bell.slash"
        }
    }
    /// A glyph on the row only when the session is not at the default.
    var rowGlyph: String? { self == .normal ? nil : symbol }
    var explanation: String {
        switch self {
        case .followed: String(localized: "Everything about this session interrupts you.")
        case .normal: String(localized: "Only approvals and failures interrupt; the rest waits in Notification Center.")
        case .muted: String(localized: "Approvals show silently; nothing else interrupts.")
        }
    }
}

/// Continue with… (ADR-0023 §4): one item per agent the Mac can start now.
/// Only a finished session with a history-side identity offers it; the sheet
/// the item opens is where the person reviews and presses Start.
struct ContinueWithMenu: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel

    private var available: Bool {
        session.status == .done && session.historyOnly != true && ContinueWith.sessionKey(for: session) != nil
            && !model.dispatchAgents.isEmpty
    }

    var body: some View {
        if available {
            Divider()
            Menu("Continue with…") {
                ForEach(model.dispatchAgents, id: \.self) { agent in
                    Button(agent.displayName) { model.requestContinue(session, with: agent) }
                }
            }
        }
    }
}
