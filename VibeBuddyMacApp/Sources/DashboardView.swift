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
    /// History and Favorites filter by project path, chosen in their own pane:
    /// the agent column's project pill narrows live sessions, not the index.
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
    /// `DashboardColumnWidth.sidebar` holds the bounds and the snap rule.
    @AppStorage("dashboard.sidebarLabeledWidth") private var sidebarLabeledWidth = Double(DashboardColumnWidth.sidebar.fullDefault)
    @AppStorage("dashboard.sidebarIconOnly") private var sidebarIconOnly = false
    /// The pointer's width while a drag on the sidebar's edge is live; nil at rest.
    @State private var sidebarDragWidth: CGFloat?
    @State private var sidebarDragOrigin: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The list's compact flag, owned here and driven by `ResizableListSplit`
    /// (the drag, the double-click); ⌘F and the strip's search glyph unfold
    /// the list so the field can take focus.
    @AppStorage(DashboardListColumn.compactKey) private var listCompact = false

    private static let sidebarPolicy = DashboardColumnWidth.sidebar
    private var sidebarSettledWidth: CGFloat {
        sidebarIconOnly ? Self.sidebarPolicy.compact : Self.sidebarPolicy.clampedFull(CGFloat(sidebarLabeledWidth))
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
        withTransaction(live) { sidebarDragWidth = Self.sidebarPolicy.clampedDuringDrag(sidebarDragOrigin + delta) }
    }

    private func sidebarDragEnded() {
        guard let released = sidebarDragWidth else { return }
        let target = Self.sidebarPolicy.settled(released: released)
        withAnimation(sidebarSettle) {
            sidebarIconOnly = target == Self.sidebarPolicy.compact
            if !sidebarIconOnly { sidebarLabeledWidth = Double(target) }
            sidebarDragWidth = nil
        }
    }

    private func sidebarToggleIconOnly() {
        withAnimation(sidebarSettle) { sidebarIconOnly.toggle() }
    }

    /// One accessibility increment or decrement: a step through the labeled
    /// range, folding to the rail below the narrowest labeled width and
    /// unfolding from it (the policy's rule).
    private func sidebarStep(_ direction: Int) {
        let next = Self.sidebarPolicy.stepped(full: CGFloat(sidebarLabeledWidth), compact: sidebarIconOnly, direction: direction)
        withAnimation(sidebarSettle) {
            sidebarIconOnly = next.compact
            sidebarLabeledWidth = Double(next.full)
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

    /// One body evaluation reads the projection many times, and only the
    /// inputs decide it; the last one is kept until an input changes.
    @State private var projectionCache = ProjectionCache()

    private var projection: DashboardSessionList {
        projectionCache.value(sessions: model.sessions, project: projectScope, status: statusFilter,
                              agent: agentFilter, query: query, selection: selection, showOlder: showOlder,
                              recentDirectories: model.recentDirectories)
    }

    final class ProjectionCache {
        private struct Key: Equatable {
            var sessions: [AgentSession]
            var project: DashboardSessionList.ProjectScope
            var status: DashboardSessionList.StatusFilter?
            var agent: AgentKind?
            var query: String
            var selection: String?
            var showOlder: Bool
            var recentDirectories: [String]
            /// The list ages finished sessions on the clock (24 h currency
            /// window), so the key carries the minute; a currency change can
            /// only be missed for under a minute.
            var minute: Int
        }
        private var key: Key?
        private var value: DashboardSessionList?

        func value(sessions: [AgentSession], project: DashboardSessionList.ProjectScope,
                   status: DashboardSessionList.StatusFilter?, agent: AgentKind?, query: String,
                   selection: String?, showOlder: Bool, recentDirectories: [String]) -> DashboardSessionList {
            let next = Key(sessions: sessions, project: project, status: status, agent: agent, query: query,
                           selection: selection, showOlder: showOlder, recentDirectories: recentDirectories,
                           minute: Int(Date().timeIntervalSince1970 / 60))
            if let value, key == next { return value }
            let computed = DashboardSessionList(sessions, project: project, status: status, agent: agent,
                                                query: query, selection: selection, showOlder: showOlder,
                                                recentDirectories: recentDirectories)
            key = next; value = computed
            return computed
        }
    }
    private func subject(for session: AgentSession) -> ReaderSubject {
        let record = SessionReaderSource.recordID(for: session).flatMap { id in history.snapshot.sessions.first { $0.id == id } }
        return ReaderSubject(origin: .live, live: session, record: record)
    }

    private var filtered: [AgentSession] { projection.visible }
    private var selectedSession: AgentSession? { projection.selected }

    /// The rail's tiles: every agent reporting, the chosen one kept listed
    /// even after its last session ages out, so the rail never shifts under
    /// the pointer.
    private var railItems: [AgentRoster.Item] {
        AgentRoster.items(model.sessions, keeping: agentFilter)
    }

    /// What the column's head says about the agent it belongs to.
    private var railTally: AgentRoster.Tally {
        railItems.first { $0.agent == agentFilter }?.tally ?? .init()
    }

    /// The rail is the agent axis now: a deep link to one agent's session
    /// must not land on a column that filters it out.
    private func reveal(_ session: AgentSession) {
        if let agentFilter, agentFilter != session.agent { self.agentFilter = session.agent }
    }

    private func projectTitle(_ scope: DashboardSessionList.ProjectScope) -> String {
        DashboardSidebar.title(scope)
    }

    /// The search field is in the agent column, over its sessions, in every
    /// library but History and Favorites — those carry their own, over their
    /// own index, so ⌘F lands on whichever one is showing.
    private func focusSearch() {
        if libraryScope == "history" || libraryScope == "favorites" { unfoldListThenFocusSearch() }
        else { searchFocused = true }
    }

    /// The search field is off screen while the list is the compact strip;
    /// unfold first (with the settle spring), then focus once it is in the tree.
    private func unfoldListThenFocusSearch() {
        if listCompact {
            withAnimation(reduceMotion ? nil : .snappy) { listCompact = false }
            DispatchQueue.main.async { searchFocused = true }
        } else {
            searchFocused = true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            DashboardAgentRail(model: model, items: railItems, selection: $agentFilter)
            Rectangle().fill(MacTheme.line).frame(width: CompanionType.hairline)
            DashboardSidebar(model: model, voice: model.voiceChat, library: $libraryScope,
                             projectScope: $projectScope, statusFilter: $statusFilter,
                             query: $query, showOlder: $showOlder,
                             agent: agentFilter, tally: railTally,
                             groups: DashboardAgentColumn.groups(filtered),
                             projects: projection.projects, olderCount: projection.olderCount,
                             selection: selection, searchFocused: $searchFocused,
                             onSelectSession: { session in
                                 libraryScope = "live"
                                 selectSession(session)
                             },
                             onNewTask: { showNewTask = true },
                             onOpenSpeech: { showSpeechPanel = true }, speechPanelPresented: showSpeechPanel,
                             width: sidebarWidth)
            Rectangle().fill(MacTheme.line).frame(width: CompanionType.hairline)
                // The drag handle straddles the hairline; it draws above the
                // content column so its pill and tip are never covered.
                .overlay {
                    ColumnResizeHandle(dragging: sidebarDragWidth != nil,
                                       accessibilityLabel: String(localized: "Sidebar width"),
                                       accessibilityValue: sidebarAccessibilityValue,
                                       accessibilityHelp: String(localized: "Drag to resize; double-click to collapse or expand the sidebar"),
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
                                     openProject: { scope in
                                         projectScope = scope
                                         statusFilter = nil
                                         query = ""
                                         showOlder = false
                                         libraryScope = "live"
                                         landOnFirst(project: scope, status: nil, agent: agentFilter)
                                     },
                                     openOlder: { openBucket(nil); showOlder = true })
                } else if libraryScope == "recap" {
                    MacRecapView(model: model)
                } else if libraryScope == "live" {
                    // The sessions moved into the agent column, so the reading
                    // takes the whole pane (ADR-0024: no right column).
                    detailColumn
                } else if libraryScope == "usage" {
                    UsageWorkbenchView(model: model)
                } else {
                    HistoryWorkbenchView(history: history, model: model, reader: reader, query: $query,
                                         favoritesOnly: libraryScope == "favorites",
                                         project: $historyProject, searchFocused: $searchFocused,
                                         listCompact: $listCompact)
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
                if let session = model.sessions.first(where: { $0.id == id }) {
                    reveal(session)
                    selectSession(session)
                }
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
        // The two libraries keep their own project choice now: the column's
        // pill narrows the live sessions, History's narrows its index.
        .onChange(of: projectScope) { _, _ in resetTour() }
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
            if projectScope != .all || statusFilter != nil || !query.isEmpty || showOlder || agentFilter != nil { openEverything() }
            libraryScope = "live"
            if let next = pendingNavigation.next(in: projection.globalPending, after: current) { selection = next.id }
    }

    private func resetTour() {
        pendingNavigation = PendingTaskNavigation()
        if let current = selectedSession { pendingNavigation.select(current, in: projection.pending) }
    }

    /// ⌘1–⌘4 and the column's group headings: one state, inside whichever
    /// agent the rail is on — the agent is a place now, not a filter to clear.
    private func openBucket(_ filter: DashboardSessionList.StatusFilter?) {
        libraryScope = "live"
        projectScope = .all
        statusFilter = filter
        query = ""
        showOlder = false
        resetTour()
        landOnFirst(project: .all, status: filter, agent: agentFilter)
    }

    /// A global route (the hotkey, the first pending task) means every agent,
    /// so it takes the rail back to All before it looks for the queue.
    private func openEverything(_ filter: DashboardSessionList.StatusFilter? = nil) {
        agentFilter = nil
        libraryScope = "live"
        projectScope = .all
        statusFilter = filter
        query = ""
        showOlder = false
        resetTour()
        landOnFirst(project: .all, status: filter, agent: nil)
    }

    /// The sessions live in the column now, so "live" is the reading itself:
    /// arriving there from a tile, a project or ⌘1–⌘4 opens the first task in
    /// that scope rather than an empty pane. A selection already inside the
    /// scope is left where it is. The scope is passed in rather than read
    /// back, because the state it comes from was set a moment ago.
    private func landOnFirst(project: DashboardSessionList.ProjectScope,
                             status: DashboardSessionList.StatusFilter?, agent: AgentKind?) {
        let scope = DashboardSessionList(model.sessions, project: project, status: status,
                                         agent: agent, selection: selection,
                                         recentDirectories: model.recentDirectories)
        if let current = selection, scope.visible.contains(where: { $0.id == current }) { return }
        guard let first = scope.visible.first else { selection = nil; return }
        pendingNavigation.select(first, in: scope.pending)
        selection = first.id
    }

    private func openFirstPending() {
        openEverything()
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

    /// The queue's foot under the reader: one strip, as the sidebar's Settings
    /// foot is — the position in the queue and the scope on the left, the
    /// `Next pending` key on the right. Why the key is disabled is its tooltip,
    /// not a third line.
    private var pendingFooter: some View {
        let queue = projection.pending
        let index = queue.firstIndex { $0.id == selection }
        let hasNext = queue.contains { $0.id != selection }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let position = pendingPosition(index: index, count: queue.count) {
                Text(position).font(MacTheme.mono(10, .medium)).foregroundStyle(MacTheme.ink2).lineLimit(1)
                Text("·").font(MacTheme.font(10.5)).foregroundStyle(MacTheme.ink3)
            }
            Text(scopeTitle).font(MacTheme.font(10.5)).foregroundStyle(MacTheme.ink3)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Next pending") {
                if let next = pendingNavigation.next(in: queue, after: selectedSession) { selection = next.id }
            }
            .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
            .disabled(!hasNext)
            .opacity(hasNext ? 1 : 0.45)
            .help(hasNext ? Text("") : Text(statusFilter == .working ? "Working sessions have no pending results in this scope." : "No other pending tasks in this scope."))
            .accessibilityIdentifier("mac-dashboard-next-pending")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(MacTheme.bg2)
        .overlay(alignment: .top) { Rectangle().fill(MacTheme.line).frame(height: CompanionType.hairline) }
    }

    /// Where the selection sits in the pending queue, or why it does not.
    private func pendingPosition(index: Int?, count: Int) -> String? {
        if let index { return "\(index + 1) / \(count)" }
        if selection != nil, selectedSession == nil { return String(localized: "Session unavailable") }
        if selectedSession?.presentationState == .idle { return String(localized: "Handled · \(count) remaining") }
        if selection != nil { return String(localized: "Outside pending · \(count) remaining") }
        return nil
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
                .frame(minWidth: DashboardListColumn.readerMinWidth, idealWidth: 520, maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                QuietEmptyState(title: selection == nil ? "Select a session" : "Session unavailable",
                                message: selection == nil ? "Pick a task on the left to see its details." : "This session is no longer available. Choose another task.")
                pendingFooter
            }
                .frame(minWidth: DashboardListColumn.readerMinWidth, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
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

    @Environment(\.listLabels) private var labels
    /// The words' width at rest, kept so a drag under the narrowest full
    /// width truncates them at the card's edge instead of reflowing every
    /// line on every pixel.
    @State private var restWordsWidth: CGFloat?

    private var presentation: RowPresentation { RowPresentation(session: session) }
    private var state: TaskPresentationState { session.presentationState }

    /// The row's words, for the tooltip when only its tile is on screen.
    private var compactTip: String {
        [session.displayTitle, presentation.activityOrResult, session.agent.displayName + " · " + session.project]
            .joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    // On the strip the tile is the whole row, so it carries
                    // the words as its tooltip and accessibility text; the
                    // branch is inside the row, so the row's identity (and
                    // its measured rest width) survives the switch.
                    if labels.iconOnly {
                        AgentTile(agent: session.agent, state: state, ground: isSelected ? MacTheme.bg2 : MacTheme.bg3)
                            .help(compactTip)
                            .accessibilityLabel(session.displayTitle)
                            .accessibilityValue(presentation.activityOrResult)
                    } else {
                        AgentTile(agent: session.agent, state: state, ground: isSelected ? MacTheme.bg2 : MacTheme.bg3)
                        words
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if showInclude, !labels.iconOnly {
                Button(action: onToggleInclude) {
                    Image(systemName: included ? "waveform.circle.fill" : "waveform.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(included ? MacTheme.accent : MacTheme.ink2)
                .accessibilityLabel(included ? "Remove from the buddy's context" : "Add to the buddy's context")
                .opacity(labels.opacity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .companionCard(isSelected ? MacTheme.bg2 : MacTheme.bg3)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                    .strokeBorder(MacTheme.accent.opacity(0.6), lineWidth: CompanionType.hairline)
                    .allowsHitTesting(false)
            }
        }
    }

    private var words: some View {
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
        // The frozen block overflows the room left beside the tile; this
        // flexible frame (min 0, or it would grow to the block) keeps the
        // row's layout honest and clips the excess, so the tile never moves.
        .frame(width: labels.transitional ? restWordsWidth ?? Self.narrowestWordsWidth : nil, alignment: .leading)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if !labels.transitional { restWordsWidth = width }
        }
        .opacity(labels.opacity)
        .transition(.opacity)
    }

    /// The words' width at the narrowest full width, for a row first laid
    /// out mid-drag: 240 − 12·2 outer − 10·2 card − 28 tile − 10 spacing.
    private static var narrowestWordsWidth: CGFloat { DashboardColumnWidth.list.minFull - 24 - 20 - 28 - 10 }
}

extension View {
    /// A list-head row on the compact strip: kept in the tree at the words'
    /// opacity so nothing under it shifts, but neither clickable nor read —
    /// and laid out at the width it has at the narrowest full width before
    /// it is given no width of its own. Without that last frame the head's
    /// ideal width, not the strip's, is what the column lays every card
    /// below it out at, and the cards are clipped at the strip's edge.
    func listHeadWords(_ labels: ColumnLabelStyle) -> some View {
        frame(width: labels.iconOnly ? DashboardListColumn.headGhostWidth : nil, alignment: .leading)
            .frame(width: labels.iconOnly ? 0 : nil, alignment: .leading)
            .opacity(labels.opacity)
            .allowsHitTesting(!labels.iconOnly)
            .accessibilityHidden(labels.iconOnly)
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
