import Combine
import SwiftUI
import VibeBuddyKit

/// The phone's dashboard (ADR-0014): a page of grouped task rows under a
/// floating row of glyph buttons, with one composer at the foot. Filtered
/// sessions retain their message rows and explicit reply targets; filtering
/// never changes the Buddy scope, subscription, or action authority.
struct DashboardView: View {
    @State private var detailCompletionNotificationID: String?
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var voice: VoiceChat
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false
    @StateObject private var settingsConnectionTest = VoiceConnectionTest()
    /// Reads the pending queue aloud (ticket 04); paused by a live voice call.
    @StateObject private var announcer = PhoneAnnouncer()
    @State private var showConnection = false
    @State private var showSettings = false
    @State private var showQuota = false
    /// What the dashboard has already started, so a return from the pushed
    /// Usage page does not reconnect or restart the demo.
    @State private var startedPairing: PairingPayload?
    @State private var launched = false
    /// Where the Usage page should land: the provider a quota widget named.
    @State private var usageFocus: UsageRequest?
    /// The New task sheet is presented by item, not by a flag: a sheet
    /// presented by `isPresented` keeps its content's `@State` across
    /// presentations, so a draft typed into the composer arrived at an
    /// empty editor (seen in QA, 2026-09-13). A fresh request is a fresh
    /// sheet with the draft as its initial prompt.
    @State private var newTaskRequest: NewTaskRequest?
    @State private var highlightId: String?
    @State private var detailId: String?
    @State private var pendingNavigation = PendingTaskNavigation()
    @State private var replyTo: String?
    @State private var filters = DashboardFilters()
    /// The inbox hub is the root (ticket 01, `.scratch/iphone-board`); the
    /// grouped list is one level down, opened from a tile or a project row.
    @State private var page: Page = .inbox
    @State private var showFilters = false
    /// The search circle on the list page reveals a field under the title.
    @State private var showSearch = false
    /// The voice page (ticket 05): opened by the mic or the voice strip.
    @State private var showVoicePage = false
    @FocusState private var searchFocused: Bool
    @State private var waitingForFilterDismiss = false
    @State private var collapsed: Set<String> = []
    /// The recency window moves with the clock, so the list re-cuts on a slow
    /// tick as well as on every snapshot.
    @State private var now = Date()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private enum Page { case inbox, list }

    private var sections: [DashboardSection] { filters.sections(from: dashboard.allSessions, now: now) }
    private var inbox: InboxProjection { InboxProjection(sessions: dashboard.allSessions, now: now) }
    private var stream: [AgentSession] { filters.sessions(from: dashboard.allSessions, now: now) }
    private var hiddenCount: Int { filters.hiddenCount(from: dashboard.allSessions, now: now) }
    private var replyTarget: AgentSession? { replyTo.flatMap { id in dashboard.allSessions.first { $0.id == id } } }
    private var detailSession: AgentSession? { detailId.flatMap { id in dashboard.allSessions.first { $0.id == id } } }
    /// The paired Mac's name is the page title; the demo has no Mac.
    private var macTitle: String {
        let name = connection.pairing?.macName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return connection.demo ? String(localized: "Demo") : "Mac"
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            if page == .list {
                header
                    .listRowInsets(.init(top: 2, leading: PhoneMetrics.gutter, bottom: 4, trailing: PhoneMetrics.gutter))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            // The connection is said once, here. Rows only add what the
            // offline state changes for them (a disabled key), and the
            // composer only speaks up when there is a draft it cannot send.
            if !dashboard.allSessions.isEmpty && dashboard.state != .connected {
                PhoneNotice(symbol: "wifi.exclamationmark",
                            text: dashboard.state == .connecting
                                ? String(localized: "Reconnecting · showing last snapshot")
                                : String(localized: "Offline · showing last snapshot"),
                            tint: CompanionPalette.status(.requiresInput)) {
                    if case .failed = dashboard.state, let pairing = connection.pairing {
                        Button("Reconnect") { dashboard.start(pairing) }
                            .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                    }
                }
                .listRowInsets(.init(top: 4, leading: PhoneMetrics.gutter, bottom: 10, trailing: PhoneMetrics.gutter))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if dashboard.allSessions.isEmpty {
                if page == .inbox {
                    inboxTitle
                        .listRowInsets(.init(top: 2, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                EmptyStateView(state: dashboard.state)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if page == .inbox {
                InboxHomeView(projection: inbox, now: now, macName: macTitle, statusLine: statusLine,
                              hiddenCount: DashboardFilters().hiddenCount(from: dashboard.allSessions, now: now),
                              openSession: { detailCompletionNotificationID = nil; detailId = $0.id },
                              openBucket: { open(bucket: $0) },
                              openProject: { open(project: $0) },
                              showOlder: { filters.bucket = nil; filters.project = nil; filters.includeInactive = true; page = .list },
                              readPending: { readPending() })
                    .listRowInsets(.init(top: 2, leading: 0, bottom: 12, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if stream.isEmpty {
                PhoneEmptyState(symbol: "line.3.horizontal.decrease",
                                title: String(localized: "No matching tasks"),
                                text: hiddenCount > 0
                                    ? String(localized: "Nothing has moved in the last 24 hours. Older tasks are in Customize.")
                                    : String(localized: "Try another filter, or reset them to see every task.")) {
                    Button("Customize") { showFilters = true }
                        .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                }
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(page == .list ? sections : []) { section in
                Section {
                    if isExpanded(section.id) {
                        ForEach(Array(section.sessions.enumerated()), id: \.element.id) { index, session in
                            TaskRow(session: session,
                                    now: now,
                                    isSelected: highlightId == session.id || replyTo == session.id,
                                    showsDivider: index < section.sessions.count - 1,
                                    onOpen: { detailCompletionNotificationID = nil; detailId = session.id })
                                .id(session.id)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) { attentionSwipeButtons(session) }
                                .contextMenu { attentionMenu(session) }
                                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    PhoneSectionHeader(title: section.title, count: section.sessions.count,
                                       expanded: expansion(section.id))
                        .padding(.horizontal, PhoneMetrics.gutter)
                        .padding(.top, 8).padding(.bottom, 5)
                        .background(CompanionPalette.bg)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if page == .list, hiddenCount > 0 {
                Button { filters.includeInactive = true } label: {
                    Label("Show \(hiddenCount) older", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                .padding(.horizontal, PhoneMetrics.gutter).padding(.vertical, 14)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(CompanionPalette.bg)
        .scrollDismissesKeyboard(.interactively)
        .onReceive(clock) { now = $0 }
        .onChange(of: dashboard.focusedSessionId) { _, _ in focus(proxy) }
        .onChange(of: dashboard.state) { _, _ in focus(proxy) }
        .onChange(of: dashboard.groups) { _, _ in
            now = Date()
            if dashboard.focusedSessionId != nil { focus(proxy) }
            if let id = replyTo, !dashboard.allSessions.contains(where: { $0.id == id }) { replyTo = nil }
        }
        .safeAreaInset(edge: .top, spacing: 0) { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if announcer.isBusy || announcer.status != nil {
                    AnnouncerStrip(announcer: announcer, replay: { announcer.replayLatest(live: { dashboard.allSessions }) })
                        .contentShape(Rectangle())
                        .onTapGesture { showVoicePage = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Open the voice page")
                }
                if voice.phase != .idle || voice.errorText != nil {
                    VoiceStrip(voice: voice)
                        .contentShape(Rectangle())
                        .onTapGesture { showVoicePage = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Open the voice page")
                }
                StreamComposer(target: replyTarget,
                               macName: connection.pairing?.macName,
                               reachable: dashboard.state == .connected,
                               receipt: replyTarget.flatMap { dashboard.phoneActionState(for: $0) },
                               voice: voice,
                               clearTarget: { replyTo = nil },
                               newTask: { newTaskRequest = NewTaskRequest(draft: "") },
                               openVoicePage: { showVoicePage = true },
                               send: send(_:target:))
            }
            .background(CompanionPalette.bg)
            // The page fades into the composer's ground, the way Cursor's list
            // slides under its composer, instead of ending on a hard edge.
            .background(alignment: .top) {
                LinearGradient(colors: [CompanionPalette.bg.opacity(0), CompanionPalette.bg],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .offset(y: -28)
            }
        }
        .animation(.smooth, value: dashboard.groups)
        .animation(.smooth, value: replyTo)
        .toolbar(.hidden, for: .navigationBar)
        .tint(CompanionPalette.accent)
        .sheet(isPresented: $showFilters, onDismiss: {
            waitingForFilterDismiss = false
            focus(proxy)
        }) {
            NavigationStack {
                DashboardCustomizeSheet(selection: $filters, sessions: dashboard.allSessions)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showConnection) {
            NavigationStack {
                DeviceConnectionView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showConnection = false }
                        }
                    }
            }
            .environmentObject(connection)
            .environmentObject(dashboard)
        }
        .navigationDestination(isPresented: $showQuota) {
            UsagePageView(focus: usageFocus)
        }
        .onChange(of: dashboard.usageRequest) { _, request in openUsage(request) }
        // A widget tap on a cold launch lands before this view exists.
        .onAppear { openUsage(dashboard.usageRequest) }
        .sheet(item: $newTaskRequest) { request in
            NewTaskSheet(dashboard: dashboard, macName: connection.pairing?.macName, initialPrompt: request.draft)
        }
        .sheet(isPresented: $showSettings) {
            // A sheet doesn't inherit the presenter's environment objects, so
            // re-inject `voice` — Settings restarts a live session on change.
            SettingsView(connectionTest: settingsConnectionTest)
                .environmentObject(announcer)
                .environmentObject(voice)
                .environmentObject(dashboard)
        }
        .sheet(isPresented: $voice.showConsent) { VoiceConsentSheet(voice: voice) }
        .sheet(isPresented: $showVoicePage) {
            VoicePageView(voice: voice, announcer: announcer,
                          scopeCount: dashboard.buddyContext.count, scopeTotal: dashboard.allSessions.count,
                          replay: { announcer.replayLatest(live: { dashboard.allSessions }) },
                          openScope: { showVoicePage = false; showFilters = true })
                .environmentObject(connection)
                .environmentObject(dashboard)
                .presentationDetents([.large])
        }
        .sheet(isPresented: Binding(get: { detailId != nil }, set: { presented in
            if !presented { detailId = nil; pendingNavigation = PendingTaskNavigation() }
        })) {
            Group {
                if let session = detailSession {
                    SessionDetailSheet(session: session, completionNotificationID: detailCompletionNotificationID,
                                       onReply: { replyTo = session.id; detailId = nil })
                        .id(session.id)
                        .environmentObject(dashboard)
                } else {
                    Text("This task is no longer available")
                        .font(CompanionType.font(14)).padding()
                }
            }
            .safeAreaInset(edge: .bottom) { pendingFooter }
        }
        .onChange(of: filters) { _, _ in pendingNavigation = PendingTaskNavigation() }
        .onChange(of: page) { _, _ in pendingNavigation = PendingTaskNavigation() }
        .onChange(of: dashboard.speechSourceIdentity) { _, _ in announcer.sourceChanged() }
        .onChange(of: voice.phase) { _, phase in if phase != .idle { announcer.voiceStarted() } }
        .onChange(of: dashboard.completionSourceID) { _, _ in pendingNavigation = PendingTaskNavigation() }
        .alert("This completion is no longer current", isPresented: $dashboard.completionLinkUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The task or paired Mac has changed. Open the current task to view its latest result. Nothing was marked read.")
        }
        .overlay(alignment: .bottom) {
            if let toast = dashboard.toast {
                Text(toast)
                    .font(CompanionType.font(13, .medium))
                    .foregroundStyle(CompanionPalette.bg3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(CompanionPalette.ink, in: Capsule())
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: dashboard.toast)
        // The Usage page is pushed onto this stack, so coming back re-runs
        // these tasks and a push fires `onDisappear`. Neither is a new
        // pairing or a teardown: the connection and the demo stay as they are.
        .task(id: connection.pairing) {
            guard let pairing = connection.pairing, startedPairing != pairing else { return }
            startedPairing = pairing
            dashboard.start(pairing)
        }
        .task {
            guard !launched else { return }
            launched = true
            if connection.demo { dashboard.startDemo() }
            await openDemoPage()
        }
        .onDisappear { if !showQuota { dashboard.stop() } }
        }
    }

    /// A quota link pushes the Usage page (or moves the open one) to the
    /// provider it names; the request is spent once it is handled.
    private func openUsage(_ request: UsageRequest?) {
        guard let request else { return }
        usageFocus = request
        showQuota = true
        dashboard.usageRequest = nil
    }

    private func openDemoPage() async {
            // `VIBEBUDDY_DEMO_PAGE=customize|usage|newtask|link/<url>|task/<title>` opens
            // that sheet once the demo has seeded, for screenshots and QA —
            // the Mac (`dashboard/<library>`) and the Watch (`WATCH_PAGE`)
            // carry the same switch.
            guard connection.demo,
                  let page = ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO_PAGE"] else { return }
            try? await Task.sleep(for: .seconds(1))
            switch page {
            case "customize": showFilters = true
            case "usage": showQuota = true
            case "newtask": newTaskRequest = NewTaskRequest(draft: "")
            case "list": open(bucket: .all)
            case "read": readPending()
            case "voice": readPending(); showVoicePage = true
            default:
                // `link/vibebuddy://quota/claude`: the deep link a widget tap
                // delivers, without the system's "Open in…" prompt `simctl
                // openurl` raises.
                if page.hasPrefix("link/"), let url = URL(string: String(page.dropFirst("link/".count))) {
                    dashboard.open(url)
                    return
                }
                if page.hasPrefix("bucket/"), let bucket = InboxBucket(rawValue: String(page.dropFirst("bucket/".count))) {
                    open(bucket: bucket)
                    return
                }
                if page.hasPrefix("project/") {
                    open(project: String(page.dropFirst("project/".count)))
                    return
                }
                guard page.hasPrefix("task/") else { return }
                let needle = String(page.dropFirst("task/".count))
                detailId = dashboard.allSessions.first {
                    $0.id == needle || $0.displayTitle.localizedCaseInsensitiveContains(needle)
                }?.id
            }
    }

    /// Speak the pending queue of the page in view: the whole snapshot from
    /// the hub, the scope from a list. Reading never marks anything read.
    private func readPending() {
        let pending = page == .inbox ? inbox.pending : pendingCandidates
        announcer.announce(pending, startPaused: voice.phase != .idle, live: { dashboard.allSessions },
                           source: { dashboard.speechSourceIdentity },
                           content: { try await dashboard.announcement(for: $0) },
                           validate: { dashboard.announcementIsCurrent($0) })
    }

    /// The scope a tile or project set, then Customize's picks: what the
    /// detail's "Next" walks through.
    private var scopeSummary: String {
        [filters.bucket != nil || filters.project != nil ? filters.scopeTitle(summary: inbox.summary) : nil,
         filters.hasCustomizePicks ? filters.summary : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The queue the detail's "Next" walks (ticket 03): the whole snapshot
    /// from the hub — "First up" is its head — and the list's scope from a
    /// bucket or project page.
    private var pendingCandidates: [AgentSession] {
        page == .inbox ? inbox.pending : filters.pendingSessions(from: dashboard.allSessions, now: now)
    }
    /// `2 / 3` for the open detail, or nothing when it is not in the queue.
    private var pendingPosition: String? {
        guard let detailSession, let index = pendingCandidates.firstIndex(where: { $0.id == detailSession.id }) else { return nil }
        return "\(index + 1) / \(pendingCandidates.count)"
    }
    private var nextPending: AgentSession? {
        var preview = pendingNavigation
        return preview.next(in: pendingCandidates, after: detailSession)
    }
    private var pendingFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let session = detailSession, let status = dashboard.completionReadStatus(for: session) {
                Text(status).font(CompanionType.font(12))
            }
            HStack(spacing: 6) {
                Text(page == .inbox ? String(localized: "All sessions")
                     : filters.isActive ? scopeSummary
                     : filters.includeInactive ? String(localized: "Current list · including older tasks")
                     : String(localized: "All sessions"))
                if let pendingPosition {
                    Text("·")
                    Text(pendingPosition).font(CompanionType.mono(10)).monospacedDigit()
                }
            }
            .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("phone-next-scope")
            if let next = nextPending {
                Button {
                    // Recompute at the tap. A deleted target cannot be opened
                    // from an earlier render, nor can this action mark it read.
                    if let target = pendingNavigation.next(in: pendingCandidates, after: detailSession) {
                        detailCompletionNotificationID = nil
                        detailId = target.id
                    }
                } label: {
                    Label("Next pending: \(next.displayTitle)", systemImage: "arrow.right")
                        .lineLimit(2)
                }
                .buttonStyle(PhoneButtonStyle(kind: .quiet))
                .accessibilityIdentifier("phone-next-pending")
            } else {
                Text("No next pending task in this scope")
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
            }
        }
        .padding(.horizontal, PhoneMetrics.gutter).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.bg)
    }

    /// A tile narrows the list to its bucket; a project row to its project.
    /// Customize's own picks (agent, attention, grouping) carry over — the
    /// tile only sets the scope the person tapped.
    private func open(bucket: InboxBucket) {
        filters.project = nil
        filters.bucket = bucket == .all ? nil : bucket
        enterList()
    }

    private func open(project: String) {
        filters.bucket = nil
        filters.project = project
        enterList()
    }

    /// Every entry starts with the groups open and no search: the list is
    /// a fresh look at the scope, not the last visit's state.
    private func enterList() {
        collapsed = []
        filters.query = ""
        showSearch = false
        page = .list
    }

    /// Back clears the scope a tile or row set and returns to the hub.
    private func backToInbox() {
        filters.bucket = nil
        filters.project = nil
        filters.query = ""
        showSearch = false
        searchFocused = false
        page = .inbox
    }

    /// Glyph buttons floating over the page. On the hub: the connection on the
    /// left, the account's allowance and Settings on the right. On the list:
    /// Back on the left, Customize and Settings on the right.
    private var toolbar: some View {
        HStack(spacing: 10) {
            if page == .inbox {
                connectionButton
            } else {
                PhoneCircleButton("chevron.left") { backToInbox() }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("phone-list-back")
            }
            Spacer(minLength: 0)
            if page == .inbox {
                PhoneCircleButton("chart.bar") { showQuota = true }
                    .accessibilityLabel("Account quota")
            } else {
                PhoneCircleButton("magnifyingglass",
                                  tint: showSearch || !filters.query.isEmpty ? CompanionPalette.accent : CompanionPalette.ink) {
                    showSearch.toggle()
                    if showSearch { searchFocused = true } else { filters.query = ""; searchFocused = false }
                }
                .accessibilityLabel("Search")
                .accessibilityIdentifier("phone-list-search")
                PhoneCircleButton("line.3.horizontal.decrease",
                                  tint: filters.hasCustomizePicks ? CompanionPalette.accent : CompanionPalette.ink) {
                    showFilters = true
                }
                .accessibilityLabel("Customize")
            }
            PhoneCircleButton("gearshape") { showSettings = true }
                .accessibilityLabel("Settings")
        }
        .padding(.horizontal, PhoneMetrics.gutter)
        .padding(.top, 6).padding(.bottom, 8)
        .background(CompanionPalette.bg)
    }

    private var connectionButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { showConnection = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                    Text(macTitle).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CompanionPalette.ink3)
                }
                .font(CompanionType.font(14, .medium))
                .foregroundStyle(CompanionPalette.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Device & connection") + Text(", ") + Text(macTitle))
            .accessibilityHint("Manage pairing and connect away from home")
            .accessibilityIdentifier("phone-inbox-connection")
            Text(DeviceConnectionView.status(pairing: connection.pairing, demo: connection.demo, state: dashboard.state))
                .font(CompanionType.font(11))
                .foregroundStyle(CompanionPalette.ink2)
                .lineLimit(2)
                .accessibilityIdentifier("phone-connection-status")
        }
    }

    /// The hub's title over an empty snapshot, so the page is still the inbox
    /// while the Mac has nothing to show.
    private var inboxTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inbox")
                .font(CompanionType.font(30, .semibold))
                .tracking(CompanionType.tracking(30))
                .foregroundStyle(CompanionPalette.ink)
            Text(macTitle)
                .font(CompanionType.font(13))
                .foregroundStyle(CompanionPalette.ink2)
        }
        .padding(.horizontal, PhoneMetrics.gutter)
    }

    /// The list page's title is the scope it was opened from — a bucket's word
    /// or a project — over the same one line about the whole snapshot.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(filters.scopeTitle(summary: inbox.summary))
                .font(CompanionType.font(30, .semibold))
                .tracking(CompanionType.tracking(30))
                .foregroundStyle(CompanionPalette.ink)
                .lineLimit(1)
                .accessibilityIdentifier("phone-list-title")
            Text(statusLine)
                .font(CompanionType.font(13))
                .foregroundStyle(CompanionPalette.ink2)
                .lineLimit(2)
            if !pendingCandidates.isEmpty {
                Button { readPending() } label: {
                    Label("Read pending", systemImage: "speaker.wave.2")
                }
                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                .padding(.top, 6)
                .accessibilityIdentifier("phone-list-read-pending")
            }
            if showSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CompanionPalette.ink3)
                    TextField(String(localized: "Search tasks"), text: $filters.query)
                        .font(CompanionType.font(14))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($searchFocused)
                        .accessibilityIdentifier("phone-list-search-field")
                    if !filters.query.isEmpty {
                        Button { filters.query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(CompanionPalette.ink3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: PhoneMetrics.control)
                .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: PhoneMetrics.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: PhoneMetrics.controlRadius)
                    .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline))
                .padding(.top, 8)
            }
            // The buddy's scope used to be the cat's subline; it is still the
            // one thing about a conversation worth a line before it starts.
            if companionEnabled, !dashboard.buddySessionIDs.isEmpty {
                Label("Voice scope: \(dashboard.buddySessionIDs.count) tasks", systemImage: "waveform")
                    .font(CompanionType.font(11))
                    .foregroundStyle(CompanionPalette.ink3)
            }
            if filters.hasCustomizePicks {
                Button { showFilters = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(filters.summary).lineLimit(1)
                    }
                }
                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                .padding(.top, 6)
            }
        }
    }

    /// `All quiet · 2 working · 1 done`, over the current sessions of the whole
    /// snapshot (`SessionCurrency`) — the same numbers the island, the widget,
    /// the Watch and the Mac panel say. A filter narrows the list, never the
    /// line that says what is going on.
    private var statusLine: String {
        let summary = TaskPresentationSummary(currentIn: dashboard.allSessions, now: now)
        let rest = summary.thinking > 0 ? String(localized: "\(summary.thinking) working") : ""
        return [CompanionCopy.attentionLine(summary), rest.isEmpty ? nil : rest]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func isExpanded(_ id: String) -> Bool { !collapsed.contains(id) }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { isExpanded(id) },
                set: { expand in if expand { collapsed.remove(id) } else { collapsed.insert(id) } })
    }


    /// What the composer's text does, decided by the message it replies to.
    private func send(_ text: String, target: AgentSession?) async -> Bool {
        guard let target else {
            newTaskRequest = NewTaskRequest(draft: text)
            return true
        }
        let result = await dashboard.answer(target.id, answer: text, expected: target)
        return result == .received
    }

    /// Scroll to and briefly highlight the session a deep link asked to open.
    /// No-ops (leaving the request pending) until that session is in the list, so
    /// a cold-start link still lands once the first snapshot arrives.
    private func focus(_ proxy: ScrollViewProxy) {
        guard !waitingForFilterDismiss, let id = dashboard.focusedSessionId else { return }
        if showFilters {
            waitingForFilterDismiss = true
            showFilters = false
            return // Resume from the filter sheet's onDismiss, retaining the exact deep link.
        }
        if let notificationID = dashboard.focusedCompletionNotificationID {
            guard dashboard.state == .connected else { return }
            let unbound = dashboard.allSessions.first { $0.id == id }?
                .isUnboundCompletionNotification(notificationID) == true
            guard unbound || dashboard.matchesCompletionNotification(notificationID, sessionID: id) else {
                dashboard.clearFocus()
                dashboard.completionLinkUnavailable = true
                return
            }
            detailCompletionNotificationID = notificationID
            detailId = id
            dashboard.clearFocus()
            return
        }
        guard dashboard.allSessions.contains(where: { $0.id == id }) else { return }
        detailCompletionNotificationID = nil
        detailId = id
        dashboard.clearFocus()
        if page == .list, stream.contains(where: { $0.id == id }) {
            withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
        }
        highlightId = id
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if highlightId == id { highlightId = nil } }
        }
    }
}

extension DashboardView {
    /// The swipe offers the two levels the row is not already at: Follow (be
    /// reminded until its completion is read; everything interrupts) and Mute
    /// (approvals and questions show silently; nothing else interrupts).
    @ViewBuilder
    fileprivate func attentionSwipeButtons(_ session: AgentSession) -> some View {
        if session.effectiveAttention != .followed {
            Button { dashboard.setAttention(session.id, .followed) } label: {
                Label(SessionAttention.followed.actionTitle, systemImage: SessionAttention.followed.symbol)
            }
            .tint(CompanionPalette.status(.requiresInput))
        }
        if session.effectiveAttention != .muted {
            Button { dashboard.setAttention(session.id, .muted) } label: {
                Label(SessionAttention.muted.actionTitle, systemImage: SessionAttention.muted.symbol)
            }
            .tint(CompanionPalette.ink3)
        }
    }

    /// The long-press shows all three plus Automatic, the current choice checked.
    /// Automatic is the daemon's own inference: followed for ten minutes after
    /// you drove the session, normal otherwise.
    @ViewBuilder
    fileprivate func attentionMenu(_ session: AgentSession) -> some View {
        if session.status == .done, session.completionID != nil {
            Button(session.hasUnreadCompletion ? "Mark as read" : "Mark as unread") {
                if session.hasUnreadCompletion {
                    dashboard.acknowledge(session.id, displayedCompletion: dashboard.completionRequest(for: session))
                } else { dashboard.markUnread(session) }
            }
        }
        Picker(selection: Binding(get: { session.attentionOverride },
                                  set: { dashboard.setAttention(session.id, $0) })) {
            Label(String(localized: "Automatic"), systemImage: "wand.and.stars")
                .tag(SessionAttention?.none)
            ForEach(SessionAttention.allCases, id: \.self) { level in
                Label(level.actionTitle, systemImage: level.symbol).tag(SessionAttention?.some(level))
            }
        } label: {
            Label(String(localized: "Attention"), systemImage: session.effectiveAttention.symbol)
        }
        .pickerStyle(.menu)
    }
}

extension SessionAttention {
    /// The verb on a swipe / menu item, and the noun in the row's accessibility label.
    var actionTitle: String {
        switch self {
        case .followed: String(localized: "Follow")
        case .normal: String(localized: "Normal")
        case .muted: String(localized: "Mute")
        }
    }
    var stateTitle: String {
        switch self {
        case .followed: String(localized: "Followed")
        case .normal: String(localized: "Normal")
        case .muted: String(localized: "Muted")
        }
    }
    var symbol: String {
        switch self {
        case .followed: "bell.badge"
        case .normal: "bell"
        case .muted: "bell.slash"
        }
    }
}


/// What a reply to a session means, from the session's own state
/// (mobile-watch-task-control: answer, instruction, continue and new task are
/// four different actions and the sender must see which one this is).
enum ReplyMeaning: Equatable {
    case answer, instruction, continuation, newTask

    init(target: AgentSession?) {
        guard let target else { self = .newTask; return }
        switch SessionActionSupport.resolve(for: target).intent {
        case .answer: self = .answer
        // The composer never resolves to stop — it carries no text — and a
        // stoppable session is a running one, whose composer is an instruction.
        case .steer, .stop: self = .instruction
        case .continue: self = .continuation
        }
    }

    var verb: LocalizedStringKey {
        switch self {
        case .answer: "Answer"
        case .instruction: "Send instruction"
        case .continuation: "Continue"
        case .newTask: "New task"
        }
    }

    var verbLabel: String {
        switch self {
        case .answer: String(localized: "Answer")
        case .instruction: String(localized: "Send instruction")
        case .continuation: String(localized: "Continue")
        case .newTask: String(localized: "New task")
        }
    }

    func placeholder(for target: AgentSession?) -> String {
        switch self {
        case .answer: String(localized: "Answer \(target?.displayTitle ?? "")…")
        case .instruction: String(localized: "Instruction for \(target?.displayTitle ?? "")…")
        case .continuation: String(localized: "Continue \(target?.displayTitle ?? "") with…")
        case .newTask: String(localized: "Plan, ask, build…")
        }
    }

    func unsupportedReason(for target: AgentSession?) -> String? {
        target.flatMap { SessionActionSupport.resolve(for: $0).unsupportedReason }
    }

    /// Said when sending works but does not land the way the verb reads — a
    /// Cursor turn cannot be interrupted, so a supplement waits for the turn to
    /// end. Shown under the field so nobody taps Send expecting otherwise.
    func note(for target: AgentSession?) -> String? {
        target.flatMap { SessionActionSupport.resolve(for: $0).note }
    }
}

/// One row of the bucket page (ticket 02): the dot, the title and the time,
/// then one line — the state word in its colour, the one fact worth a
/// glance (`+41 −12`, a step, the question or the result) and the project
/// when the title does not already say it. No keys: the detail decides,
/// the swipe follows or mutes.
private struct TaskRow: View {
    let session: AgentSession
    let now: Date
    let isSelected: Bool
    let showsDivider: Bool
    let onOpen: () -> Void

    private var presentation: RowPresentation { RowPresentation(session: session) }
    private var state: TaskPresentationState { session.presentationState }
    private var stateWord: String { ToolActivity.label(for: session) }
    private var detail: String? {
        if let stats = session.ledgerSummary, !stats.isEmpty { return stats }
        if let progress = presentation.progress, !progress.isEmpty { return progress }
        let activity = presentation.activityOrResult
        return activity.isEmpty || activity == stateWord ? nil : activity
    }
    private var projectTitle: String? {
        let title = DashboardFilters.projectTitle(session.project)
        return title == session.displayTitle ? nil : title
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: PhoneRowMetrics.textInset - PhoneRowMetrics.dot) {
                    StatusDot(state: state, size: PhoneRowMetrics.dot)
                        .padding(.top, 7)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(session.displayTitle)
                                .font(CompanionType.font(16))
                                .tracking(CompanionType.tracking(16))
                                .foregroundStyle(CompanionPalette.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            HStack(spacing: 5) {
                                if session.effectiveAttention != .normal {
                                    Image(systemName: session.effectiveAttention == .followed ? "bell.badge" : "bell.slash")
                                        .font(.system(size: 10, weight: .medium))
                                        .accessibilityLabel(session.effectiveAttention.stateTitle)
                                }
                                Text(PhoneRelativeTime.short(session.updatedAt, now: now))
                                    .font(CompanionType.font(11)).monospacedDigit()
                            }
                            .foregroundStyle(CompanionPalette.ink3)
                        }
                        HStack(spacing: 5) {
                            Text(stateWord).foregroundStyle(CompanionPalette.status(state))
                            if let detail {
                                Text("·")
                                Text(detail).lineLimit(1).truncationMode(.tail)
                                    .font(detail == session.ledgerSummary ? CompanionType.mono(12) : CompanionType.font(13))
                            }
                            if let projectTitle {
                                Text("·")
                                Text(projectTitle).lineLimit(1).layoutPriority(1)
                            }
                        }
                        .font(CompanionType.font(13))
                        .foregroundStyle(CompanionPalette.ink3)
                        .lineLimit(1)
                    }
                }
                .padding(.horizontal, PhoneMetrics.gutter)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? CompanionPalette.accent.opacity(0.08) : .clear)
                // The whole row, blank space included, opens the task.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Open details")
            if showsDivider { PhoneDivider(leading: PhoneMetrics.gutter + PhoneRowMetrics.textInset) }
        }
    }

    private var accessibilityLabel: String {
        [session.displayTitle, stateWord, detail ?? "", projectTitle ?? "",
         session.effectiveAttention == .normal ? "" : session.effectiveAttention.stateTitle,
         presentation.unread ? String(localized: "Unread") : "",
         PhoneRelativeTime.spoken(session.updatedAt, now: now)]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum PhoneRowMetrics {
    static let dot: CGFloat = 8
    static let textInset: CGFloat = 18
}

/// The composer says whom the text goes to and what it means. With a reply
/// target the banner names both; without one the text is a new task. `+` starts
/// one from scratch, and the mic is the voice companion the cat used to host.
private struct StreamComposer: View {
    let target: AgentSession?
    let macName: String?
    let reachable: Bool
    let receipt: PhoneActionResult?
    @ObservedObject var voice: VoiceChat
    let clearTarget: () -> Void
    let newTask: () -> Void
    let openVoicePage: () -> Void
    let send: (String, AgentSession?) async -> Bool
    @State private var sending = false
    @State private var draftTarget: AgentSession?
    @State private var draft = ""
    @FocusState private var focused: Bool
    @AppStorage("composer.micHintSeen") private var micHintSeen = false

    private var meaning: ReplyMeaning { ReplyMeaning(target: target) }
    private var unsupported: String? { meaning.unsupportedReason(for: target) }
    private var canSend: Bool {
        reachable && !sending && unsupported == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            if let target {
                // Two lines: what the text will do and to whom, then where
                // that is. The card takes the height of its text and no more.
                HStack(alignment: .top, spacing: 8) {
                    StatusDot(state: target.presentationState, size: PhoneRowMetrics.dot)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(meaning.verbLabel)
                                .font(CompanionType.font(12, .medium)).foregroundStyle(CompanionPalette.ink)
                            Text("·").foregroundStyle(CompanionPalette.ink3)
                            Text(target.displayTitle)
                                .font(CompanionType.font(12, .medium)).foregroundStyle(CompanionPalette.ink)
                                .lineLimit(1)
                        }
                        Text(unsupported ?? "\(ToolActivity.label(for: target)) · \(SessionActionSupport.targetCaption(macName: macName, session: target))")
                            .font(CompanionType.font(11))
                            .foregroundStyle(unsupported == nil ? CompanionPalette.ink3 : CompanionPalette.status(.error))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button(action: clearTarget) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CompanionPalette.ink3)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .companionCard()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                PhoneCircleButton("plus", size: 30, tint: CompanionPalette.ink2,
                                  ground: CompanionPalette.bg2, action: newTask)
                    .accessibilityLabel("New task")
                TextField(meaning.placeholder(for: target), text: $draft, axis: .vertical)
                    .font(CompanionType.font(14))
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.vertical, 6)
                    .onSubmit(submit)
                // The mic is the voice companion's entry point (ADR-0017 §3):
                // always here, whether or not a draft is being typed.
                PhoneCircleButton(voiceGlyph, size: 30,
                                  tint: voice.phase == .idle ? CompanionPalette.ink2 : .onAccent,
                                  ground: voice.phase == .idle ? CompanionPalette.bg2 : CompanionPalette.accent) {
                    micHintSeen = true
                    let starting = voice.phase == .idle
                    voice.toggle()
                    // Starting a call opens the page; ending one just ends it.
                    if starting, voice.isEnabled { openVoicePage() }
                }
                .accessibilityLabel(voice.phase == .idle ? "Start voice conversation" : "End voice conversation")
                if hasDraft {
                    PhoneCircleButton("arrow.up", size: 30, tint: .onAccent,
                                      ground: canSend ? CompanionPalette.accent : CompanionPalette.ink3,
                                      action: submit)
                        .disabled(!canSend)
                        .accessibilityLabel(meaning.verbLabel)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline)
            }
            if sending {
                Text("Sending…")
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            } else if let receipt {
                Text(receipt.message)
                    .font(CompanionType.font(11))
                    .foregroundStyle(receiptColor(receipt))
            } else if !reachable, hasDraft {
                // The page already says it is offline; the composer only adds
                // that this draft is staying here.
                Text("Couldn't reach your Mac — not sent")
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.status(.error))
            } else if unsupported == nil, let note = meaning.note(for: target) {
                Text(note)
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            } else if target == nil, hasDraft {
                // Text with no target is a new task. Said here, so a draft
                // that lost its reply target is not sent somewhere by surprise.
                Text("Sends as a new task — you pick the folder and agent next")
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            } else if !micHintSeen, !hasDraft, voice.phase == .idle, voice.errorText == nil {
                // Said once: the mic is explained the first time it appears,
                // then it is just the mic (ADR-0017 §3).
                Text("Tap the mic to talk to your sessions")
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .onChange(of: draft) { old, new in
            if old.isEmpty, !new.isEmpty { draftTarget = target }
        }
        .onChange(of: target?.id) { _, id in
            // An explicit Reply/cancel changes the intended destination; a new
            // wait in the same task does not retarget an existing draft.
            draftTarget = target
            if id != nil { focused = true }
        }
    }

    private var voiceGlyph: String {
        switch voice.phase {
        case .idle: return "mic"
        case .listening: return "mic.fill"
        case .speaking: return "waveform"
        case .connecting, .recovering, .thinking: return "ellipsis"
        }
    }

    private func receiptColor(_ receipt: PhoneActionResult) -> Color {
        switch receipt {
        case .received, .sending: CompanionPalette.ink2
        case .unconfirmed, .notPaired, .expired, .failed: CompanionPalette.status(.error)
        }
    }

    private func submit() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalDraft = draft
        let originalTarget = draftTarget
        sending = true
        Task {
            if await send(text, originalTarget), draft == originalDraft,
               draftTarget?.id == originalTarget?.id,
               draftTarget?.pendingQuestion?.id == originalTarget?.pendingQuestion?.id,
               draftTarget?.statusSince == originalTarget?.statusSince {
                draft = ""; focused = false; draftTarget = nil
                clearTarget()
            }
            sending = false
        }
    }
}

/// Everything the row keeps behind it: the session's numbers, context, health,
/// how much it may interrupt you, and the ways to reach it.
private struct SessionDetailSheet: View {
    let session: AgentSession
    var completionNotificationID: String? = nil
    let onReply: () -> Void
    @EnvironmentObject private var dashboard: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showChanges = false
    @State private var completionBody: CompletionBody?
    @State private var resultIsVisible = false
    @State private var acknowledgedBodyID: String?
    private var resultKey: String { (dashboard.completionSourceID ?? "unknown") + "/" + session.id + "/" + (session.completionID ?? "working") }
    private var currentBody: CompletionBody? {
        guard let completionBody, completionBody.sourceID == dashboard.completionSourceID, completionBody.sessionID == session.id,
              completionBody.completionID == session.completionID else { return nil }
        return completionBody
    }
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    private var state: TaskPresentationState { session.presentationState }
    private var included: Bool { dashboard.buddySessionIDs.contains(session.id) }

    var body: some View {
        VStack(spacing: 0) {
            PhoneSheetHeader(title: String(localized: "Task")) { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        AgentAvatar(agent: session.agent, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.taskGoal).lineLimit(3)
                                .font(CompanionType.font(22, .semibold))
                                .tracking(CompanionType.tracking(22))
                                .foregroundStyle(CompanionPalette.ink)
                                .lineLimit(2)
                            // The same line the row carries: the state word in
                            // its colour, then agent, project and branch.
                            HStack(spacing: 5) {
                                StatusDot(state: state, size: PhoneRowMetrics.dot)
                                Text(ToolActivity.label(for: session))
                                    .foregroundStyle(CompanionPalette.status(state))
                                Text("·")
                                Text(session.agent.shortName)
                                if DashboardFilters.projectTitle(session.project) != session.displayTitle {
                                    Text("·")
                                    Text(DashboardFilters.projectTitle(session.project))
                                }
                                if let branch = session.branch {
                                    Text("·")
                                    Text(branch).font(CompanionType.mono(10)).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                            .lineLimit(1)
                        }
                    }
                    if session.completionNotice?.state == .pending {
                        Text("Preparing completion summary…")
                            .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                    }
                    if let id = completionNotificationID,
                       !dashboard.matchesCompletionNotification(id, sessionID: session.id) {
                        if session.isUnboundCompletionNotification(id) {
                            Text("This notification does not identify a completion round. Review the current result before marking it read.")
                                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                            Button("Mark current result read") { dashboard.acknowledgeDisplayedCompletion(session) }
                                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                        } else {
                            Text("This task has moved on. You are viewing its current state, not the result from that notification.")
                                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                        }
                    }
                    if let summary = session.detailProgress, !summary.isEmpty {
                        Text(summary).font(CompanionType.font(14)).foregroundStyle(CompanionPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if session.status == .done, session.completionID != nil {
                        if let body = currentBody {
                            if let text = body.text {
                                Text(text).font(CompanionType.font(14)).foregroundStyle(CompanionPalette.ink)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                .completionReadingVisibility { visible in
                                    resultIsVisible = visible; acknowledgeVisibleBody()
                                }
                                Text("Agent final response · this completion · not independently verified")
                                    .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3)
                            } else if let reason = body.unavailableReason {
                                Text(LocalizedStringKey(reason)).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                            }
                        } else { Text("Loading this completion…").font(CompanionType.font(11)) }
                        Button(session.hasUnreadCompletion ? "Mark as read" : "Mark as unread") {
                            acknowledgedBodyID = resultKey
                            if session.hasUnreadCompletion {
                                dashboard.acknowledge(session.id, displayedCompletion: dashboard.completionRequest(for: session))
                            } else { dashboard.markUnread(session) }
                        }.buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                    }
                    Text(ToolActivity.label(for: session)).font(CompanionType.font(12))
                        .foregroundStyle(CompanionPalette.ink2)
                    Text(session.detailProgressSource).font(CompanionType.font(10))
                        .foregroundStyle(CompanionPalette.ink3)
                    if session.status == .needsResponse {
                        Text("Your decision").font(CompanionType.font(12, .semibold))
                        decision
                    }
                    Text("Actions").font(CompanionType.font(12, .semibold))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications").font(CompanionType.font(11, .medium)).textCase(.uppercase).kerning(0.5)
                            .foregroundStyle(CompanionPalette.ink3)
                        HStack(spacing: 6) {
                            PhoneChip(title: String(localized: "Auto"), selected: session.attentionOverride == nil) {
                                dashboard.setAttention(session.id, nil)
                            }
                            ForEach(SessionAttention.allCases, id: \.self) { level in
                                PhoneChip(title: level.stateTitle, selected: session.attentionOverride == level) {
                                    dashboard.setAttention(session.id, level)
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Attention")
                    }
                    HStack(spacing: 8) {
                        if session.canJump {
                            Button(session.agent == .grokBot ? "Open Grok Bot" : session.jumpsToDesktopThread ? "Open thread in ChatGPT" : "Jump to terminal") {
                                dashboard.jump(session.id)
                            }
                            .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.accent)))
                        }
                        if SessionActionSupport.resolve(for: session).isAvailable {
                            Button { onReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                                .buttonStyle(PhoneButtonStyle(kind: .quiet))
                        }
                        if companionEnabled {
                            Button { dashboard.toggleBuddy(session.id) } label: {
                                Label(included ? "In buddy's context" : "Add to buddy", systemImage: included ? "waveform.circle.fill" : "waveform.circle")
                            }
                            .buttonStyle(PhoneButtonStyle(kind: .quiet))
                        }
                    }
                    DisclosureGroup("Activity and file changes") {
                        Button("Changes") { showChanges = true }.buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                        ToolLedgerView(session: session)
                        RecentOutputCard(output: dashboard.recentOutputs[session.id])
                        metaCard
                    }
                }
                .padding(.horizontal, PhoneMetrics.gutter)
                .padding(.bottom, 24)
            }
        }
        .background(CompanionPalette.bg)
        .presentationDetents([.medium, .large])
        .tint(CompanionPalette.accent)
        .sheet(isPresented: $showChanges) {
            WorkspaceChangesView { scope, baseline, file in
                await dashboard.workspaceChanges(for: session, scope: scope, baseline: baseline, file: file)
            }
        }
        .task { await dashboard.loadRecentOutput(session.id) }
        .task(id: resultKey) {
            completionBody = nil
            resultIsVisible = false
            let key = resultKey
            let loaded = await dashboard.completionBody(for: session)
            guard !Task.isCancelled, key == resultKey else { return }
            completionBody = loaded
        }
        .onChange(of: currentBody) { _, _ in acknowledgeVisibleBody() }
        .onChange(of: scenePhase) { _, _ in acknowledgeVisibleBody() }
        .onChange(of: showChanges) { _, _ in acknowledgeVisibleBody() }
    }

    private func acknowledgeVisibleBody() {
        guard scenePhase == .active, !showChanges, resultIsVisible, currentBody?.text?.isEmpty == false,
              session.hasUnreadCompletion, acknowledgedBodyID != resultKey else { return }
        acknowledgedBodyID = resultKey
        dashboard.acknowledge(session.id, displayedCompletion: dashboard.completionRequest(for: session))
    }

    @ViewBuilder private var decision: some View {
        if let approval = session.pendingApproval {
            ApprovalBody(approval: approval)
            if ApprovalEligibility.approval(for: session) != nil {
                HStack {
                    Button("Approve") { dashboard.decide(approval.id, .allow) }
                        .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.accent)))
                    Button("Deny") { dashboard.decide(approval.id, .deny) }
                        .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.status(.error))))
                }.disabled(dashboard.phoneActionDisabled(for: session))
            } else { Text(WaitHandling.resolve(for: session).message) }
        } else if let question = session.pendingQuestion {
            if WaitHandling.resolve(for: session) == .remoteAvailable {
                QuestionCardView(question: question, actionState: dashboard.phoneActionState(for: session)) { answers in
                    await dashboard.answer(session.id, answers: answers, expected: session)
                }.disabled(dashboard.phoneActionDisabled(for: session))
            } else {
                Text(question.prompt)
                Text(WaitHandling.resolve(for: session).message)
            }
        } else { Text(WaitHandling.resolve(for: session).message) }
    }

    private var metaCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let model = session.model { meta("Model", model) }
            if let tokens = session.tokens { meta("Tokens", tokens.formatted()) }
            if let cost = session.estimatedCostUSD {
                meta("Cost", "\(session.costUSD == nil ? "≈ " : "")$" + String(format: "%.2f", cost))
            }
            if let effort = session.effort { meta("Effort", effort) }
            if let pr = session.prNumber { meta("PR", "#\(pr)") }
            if let worktree = session.worktree { meta("Worktree", worktree) }
            if let used = session.contextTokens, let window = session.contextWindow, window > 0 {
                ContextBar(used: used, window: window)
            }
            if let observation = session.observationDescription {
                HStack(spacing: 5) {
                    Label(observation, systemImage: "waveform.path.ecg")
                    if let last = session.lastObservedAt { Text("· \(PhoneRelativeTime.short(last))") }
                }
                .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
            }
            if let child = ToolActivity.childSummary(for: session) {
                Text(child).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            }
            HStack(spacing: 4) {
                Image(systemName: session.status == .needsResponse ? "hourglass" : "clock")
                Text(session.statusSince, style: .timer).monospacedDigit()
            }
            .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard()
    }

    private func meta(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            Spacer()
            Text(value).font(CompanionType.mono(11)).foregroundStyle(CompanionPalette.ink).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Expandable bounded recent dialogue. The expanded text is the same slice
/// the collapsed preview came from — there is no fuller history behind it.
private struct RecentOutputCard: View {
    let output: RecentOutput?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Text("Recent output").font(CompanionType.font(11, .medium)).textCase(.uppercase).kerning(0.5)
                        .foregroundStyle(CompanionPalette.ink3)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CompanionPalette.ink3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide recent output" : "Show recent output")

            if let output {
                meta(output)
                if expanded {
                    entries(output)
                } else if let last = output.entries.last {
                    preview(last)
                }
                if !output.statusLine.isEmpty {
                    Text(output.statusLine)
                        .font(CompanionType.font(11))
                        .foregroundStyle(CompanionPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Loading recent output…")
                    .font(CompanionType.font(11))
                    .foregroundStyle(CompanionPalette.ink3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard()
    }

    private func meta(_ output: RecentOutput) -> some View {
        HStack(spacing: 6) {
            Text(output.sourceLabel)
            if let updatedAt = output.updatedAt {
                Text("·")
                Text(PhoneRelativeTime.short(updatedAt)).monospacedDigit()
            }
        }
        .font(CompanionType.font(11))
        .foregroundStyle(CompanionPalette.ink3)
    }

    @ViewBuilder
    private func entries(_ output: RecentOutput) -> some View {
        ForEach(Array(output.entries.enumerated()), id: \.offset) { _, entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.role == "assistant" ? "Assistant" : "You")
                    .font(CompanionType.font(10, .medium))
                    .foregroundStyle(entry.role == "assistant" ? CompanionPalette.accent : CompanionPalette.ink3)
                Text(entry.text)
                    .font(CompanionType.font(13))
                    .foregroundStyle(CompanionPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func preview(_ entry: RecentOutputEntry) -> some View {
        Text(entry.text)
            .font(CompanionType.font(13))
            .foregroundStyle(CompanionPalette.ink)
            .lineLimit(3)
    }
}


private struct ContextBar: View {
    let used: Int
    let window: Int

    var body: some View {
        let frac = min(1.0, Double(used) / Double(max(window, 1)))
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: frac).tint(color(frac))
            Text("\(short(used)) / \(short(window)) context")
                .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3).monospacedDigit()
        }
        .padding(.top, 2)
    }

    /// The quota bars' rule: the accent while there is room, the severity
    /// tints past 70 % and 90 %.
    private func color(_ f: Double) -> Color {
        f > 0.9 ? CompanionPalette.status(.error)
            : f > 0.7 ? CompanionPalette.status(.requiresInput) : CompanionPalette.accent
    }
    private func short(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }
}

/// The page with nothing on it, in the phone's own type. `moon.zzz` is the
/// empty glyph on every status surface (ADR-0017 §2).
private struct EmptyStateView: View {
    @State private var showMacHelp = false
    let state: DashboardStore.ConnectionState

    var body: some View {
        switch state {
        case .connecting:
            PhoneEmptyState(symbol: "antenna.radiowaves.left.and.right",
                            title: String(localized: "Connecting to your Mac"))
        case .connected:
            PhoneEmptyState(symbol: "moon.zzz",
                            title: String(localized: "No active tasks"),
                            text: String(localized: "Start a Claude Code or Codex session and it'll show up here."))
        case .failed(let message):
            PhoneEmptyState(symbol: "wifi.exclamationmark",
                            title: String(localized: "Disconnected"),
                            text: message + "\n" + String(localized: "Check that the Mac app is running, both devices are on the same local network, and Local Network access is enabled in Settings.")) {
                Button("Need the Mac companion?") { showMacHelp = true }
                    .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
            }
            .sheet(isPresented: $showMacHelp) { MacCompanionSetupSheet() }
        }
    }
}

/// Inline consent before the voice companion's first use: you tapped the mic, so
/// the ask is here, not buried in Settings. Continuing persists the opt-in; it
/// does not open the mic — the next tap starts the call.
private struct VoiceConsentSheet: View {
    @ObservedObject var voice: VoiceChat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            PhoneSheetHeader(title: String(localized: "Voice companion")) { dismiss() }
            VStack(alignment: .leading, spacing: 16) {
                Text("Tap the mic to talk with your selected AI provider: Qwen (DashScope), OpenAI, or Gemini (Google).")
                    .foregroundStyle(CompanionPalette.ink2)
                Text("When you start a voice conversation, your microphone audio and selected session context (project names, agent type, status, and summaries) are sent directly to that provider using your own API key. The key stays in Keychain and nothing passes through a vibebuddy server.")
                    .foregroundStyle(CompanionPalette.ink2)
                Text("Continuing keeps the mic off until your next tap.")
                    .foregroundStyle(CompanionPalette.ink3)
                Spacer()
                Button { voice.enableCompanion(); dismiss() } label: {
                    Text("Continue")
                }
                .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.accent), size: .wide))
            }
            .font(CompanionType.font(14))
            .padding(.horizontal, PhoneMetrics.gutter)
            .padding(.bottom, 20)
        }
        .background(CompanionPalette.bg)
        .presentationDetents([.medium])
    }
}

/// One request to open the New task sheet, carrying the composer's draft.
private struct NewTaskRequest: Identifiable {
    let id = UUID()
    let draft: String
}
