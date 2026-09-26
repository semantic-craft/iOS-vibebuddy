import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// The selected agent's workspace, beside the agent rail: who is working, what
/// their account has left, a task you can start in their name, the five
/// libraries, and their live sessions grouped by what each one wants from you.
/// It replaces the old project list — a long, churning column of worktree
/// hashes — with the one axis that stays still, and takes over the session
/// list the reader used to sit beside, so the reading gets the whole pane.
struct DashboardSidebar: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var voice: VoiceChat
    @Binding var library: String
    @Binding var projectScope: DashboardSessionList.ProjectScope
    @Binding var statusFilter: DashboardSessionList.StatusFilter?
    @Binding var query: String
    @Binding var showOlder: Bool
    /// The rail's choice; `nil` is "All agents".
    let agent: AgentKind?
    let tally: AgentRoster.Tally
    /// The filtered sessions, already ranked, split into the groups the column
    /// reads in order (`DashboardAgentColumn.groups`).
    let groups: [DashboardAgentColumn.Group]
    let projects: [DashboardSessionList.Project]
    let olderCount: Int
    let selection: String?
    var searchFocused: FocusState<Bool>.Binding
    var onSelectSession: (AgentSession) -> Void
    var onNewTask: () -> Void
    var onOpenSpeech: () -> Void
    var speechPanelPresented: Bool
    /// The column's width right now: a settled width, or the pointer's while
    /// a drag on the right edge is live (`DashboardColumnWidth.sidebar`). Every row
    /// reads its lettering from it, so labels truncate and fade as the
    /// column narrows and the glyphs never move.
    var width: CGFloat = DashboardColumnWidth.sidebar.fullDefault
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false
    /// The one-line "where voice lives" note shows until the dashboard has been
    /// closed once with it on screen (ADR-0017 §3).
    @AppStorage("dashboard.voiceHintSeen") private var voiceHintSeen = false

    private var labels: ColumnLabelStyle { .at(width: width, policy: .sidebar) }
    private var waiting: Int { TaskPresentationSummary(currentIn: model.sessions, now: Date()).pendingCount }
    private var agentName: String { agent?.displayName ?? String(localized: "All agents") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The head never scrolls: New task, the libraries and the filters
            // stay reachable at any session count; only the sessions move.
            VStack(alignment: .leading, spacing: 1) {
                agentHeader
                newTaskRow
                voiceRow
                SidebarRow(systemName: "text.bubble", title: "Voice and reading", action: onOpenSpeech)

                SidebarHeading(title: "Library")
                SidebarRow(systemName: "tray", title: "Inbox",
                           count: waiting, countTint: MacTheme.status(.requiresInput),
                           selected: library == "inbox") { library = "inbox" }
                SidebarRow(systemName: "chart.bar", title: "Usage", selected: library == "usage") { library = "usage" }

                sessionsHeading
                if !labels.iconOnly {
                    SearchPill(query: $query, focused: searchFocused)
                        .padding(.horizontal, 8).padding(.bottom, 6)
                        .opacity(labels.opacity)
                }
            }
            .padding(.horizontal, 8).padding(.top, 10)

            sessionList
            Spacer(minLength: 0)
        }
        .environment(\.sidebarLabels, labels)
        .frame(width: width).frame(maxHeight: .infinity)
        .clipped()
        .background(MacTheme.bg2)
        .sheet(isPresented: Binding(get: { voice.showConsent && !speechPanelPresented }, set: { voice.showConsent = $0 })) { VoiceConsentSheet(voice: voice) }
        .onDisappear { if !companionEnabled { voiceHintSeen = true } }
    }

    // MARK: The agent

    /// Who the column belongs to, and what their account has left. On the
    /// strip only the mark stays — the rail beside it already carries the
    /// same identity, so the words go to the tooltip rather than wrap.
    private var agentHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if let agent {
                        SVGPathShape(agent.brandMark).fill(agent.brandColor).frame(width: 15, height: 15)
                    } else {
                        Image(systemName: "square.grid.2x2").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MacTheme.ink2).frame(width: 15, height: 15)
                    }
                }
                .frame(width: 14, alignment: .leading)
                if !labels.iconOnly {
                    Text(agentName).font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text("\(tally.total)").font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                }
            }
            .opacity(labels.iconOnly ? 1 : labels.opacity)
            // The name and its count read as one heading; the quota below
            // stays its own button instead of being folded into the label.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(agentName))
            .accessibilityValue(tally.total == 1 ? Text("1 session") : Text("\(tally.total) sessions"))
            .accessibilityAddTraits(.isHeader)
            if !labels.iconOnly { quotaStrip }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    /// The agent's allowance where the agent is, rather than in a plinth of
    /// its own: its share and its reset, one line per pool. Most agents have
    /// one; Cursor runs two independent pools over the same billing period, and
    /// the spent one never hides behind the comfortable one.
    @ViewBuilder private var quotaStrip: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let readings = agent.map { AgentQuotaReading.readAll($0, model: model, now: context.date) }
                ?? AgentQuotaReading.tightest(model: model, now: context.date).map { [$0] } ?? []
            if !readings.isEmpty {
                let summary = readings.map { $0.summaryLine(now: context.date) }
                Button { DashboardRoute.open(.usage) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(readings) { reading in
                            quotaRow(reading, now: context.date)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Account quota · \(summary.joined(separator: " · "))"))
                .accessibilityLabel("Account quota")
                .accessibilityValue(summary.joined(separator: ", "))
                .opacity(labels.opacity)
            }
        }
    }

    private func quotaRow(_ reading: AgentQuotaReading, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // Under All the provider has to be named; under an agent the
                // provider is the row above. Either way the pool is named, so
                // "0%" never stands for an account without saying which pool.
                Text(agent == nil && reading.windowName != reading.provider.displayName
                     ? "\(reading.provider.displayName) · \(reading.windowName)"
                     : (agent == nil ? reading.provider.displayName : reading.windowName))
                    .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(reading.remainingPercent)%")
                    .font(MacTheme.mono(10, .semibold)).foregroundStyle(reading.tint)
                if let warning = reading.warningText(now: now) {
                    Text(warning).font(MacTheme.font(10)).foregroundStyle(QuotaPresentation.Severity.warning.tint)
                        .lineLimit(1)
                } else if let reset = reading.resetText(now: now) {
                    Text(reset).font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3).lineLimit(1)
                }
            }
            QuotaBullet(usedPercent: reading.usedPercent, pacePercent: nil, height: 4)
        }
    }

    /// New task in the agent's name: the rail's choice is the one the sheet
    /// opens on, so starting work is the same gesture as reading it.
    private var newTaskRow: some View {
        SidebarRow(systemName: "plus.square",
                   title: agent == nil ? "New task" : LocalizedStringKey(String(localized: "New \(agentName) task")),
                   shortcut: "⌘N", action: onNewTask)
    }

    // MARK: Sessions

    private var anyFilter: Bool {
        projectScope != .all || statusFilter != nil || !query.isEmpty || showOlder
    }

    private var sessionsHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SidebarHeading(title: "Sessions")
            if !labels.iconOnly {
                Spacer(minLength: 0)
                projectPill
                if anyFilter {
                    Button("Reset") {
                        projectScope = .all
                        statusFilter = nil
                        query = ""
                        showOlder = false
                    }
                    .buttonStyle(.plain).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
                    .padding(.vertical, 4).contentShape(Rectangle())
                }
            }
        }
        .padding(.trailing, 8)
        .opacity(labels.iconOnly ? 1 : labels.opacity)
    }

    /// Projects stay one menu away: the column is the agent's, and this is
    /// where "…in this checkout" narrows it.
    private var projectPill: some View {
        let titles = DashboardProjectLabel.labels(for: projects.map { Self.title($0.id) })
        return MenuPill(title: projectScope == .all
                        ? String(localized: "All projects")
                        : titles[Self.title(projectScope)]?.title ?? Self.title(projectScope),
                        emphasized: projectScope != .all) {
            Button("All projects") { projectScope = .all }
            ForEach(projects) { project in
                let full = Self.title(project.id)
                Button(project.count > 0 ? "\(titles[full]?.title ?? full) (\(project.count))" : (titles[full]?.title ?? full)) {
                    projectScope = project.id
                }
            }
        }
        .accessibilityLabel("Filter sessions by project")
    }

    @ViewBuilder private var sessionList: some View {
        if labels.iconOnly {
            // The strip has no words, and a session row is all words; the rail
            // beside it still carries the agent's attention dot.
            EmptyView()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if groups.isEmpty {
                        Text(anyFilter ? "No matching sessions" : "No sessions reporting")
                            .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
                            .padding(.horizontal, 16).padding(.top, 10)
                    }
                    ForEach(groups) { group in
                        GroupHeading(filter: group.filter, count: group.sessions.count,
                                     selected: statusFilter == group.filter) {
                            statusFilter = statusFilter == group.filter ? nil : group.filter
                        }
                        ForEach(group.sessions) { session in
                            AgentSessionRow(session: session, showAgent: agent == nil,
                                            selected: selection == session.id,
                                            included: model.buddySessionIDs.contains(session.id),
                                            showInclude: companionEnabled) {
                                onSelectSession(session)
                            }
                            .contextMenu {
                                AttentionPicker(session: session, model: model, style: .menu)
                                if companionEnabled {
                                    Button(model.buddySessionIDs.contains(session.id) ? "Remove from Buddy" : "Include in Buddy") {
                                        model.toggleBuddy(session.id)
                                    }
                                }
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
                    if olderCount > 0 || showOlder {
                        Toggle(isOn: $showOlder) { Text("Show \(olderCount) older") }
                            .toggleStyle(.checkbox).font(MacTheme.font(10.5))
                            .padding(.horizontal, 10).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
                .opacity(labels.opacity)
            }
        }
    }

    // MARK: Voice

    /// The mic is Cursor's small round button, here on its own row: the row
    /// toggles the conversation, the trailing word is its state, and a second
    /// line carries the last exchange or the error. The cat sits beside the
    /// mic only while a conversation is live (ADR-0017 §2–3). The 20pt disc
    /// is centred on the 14pt glyph column its neighbours use, so its centre
    /// and the word after it line up with New task; the row gives
    /// back the extra height in its padding and stays as tall as theirs.
    private var voiceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { voice.toggle() } label: {
                HStack(spacing: 8) {
                    MicGlyph(phase: voice.phase, enabled: companionEnabled).frame(width: 14)
                    if !labels.iconOnly {
                        Group {
                            if voice.isActive {
                                PetFace(state: model.buddyState, voice: .init(voice.phase), plain: true, scale: 0.36)
                                    .frame(width: 18, height: 18)
                            }
                            Text("Voice").font(MacTheme.font(12, .medium)).foregroundStyle(MacTheme.ink).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(stateWord).font(MacTheme.mono(10)).foregroundStyle(stateTint).lineLimit(1)
                        }
                        .opacity(labels.opacity)
                        .transition(.opacity)
                    }
                }
                .sidebarRowFrame(minHeight: 20, vertical: 3)
            }
            .buttonStyle(SidebarRowStyle(selected: voice.isActive))
            .help(voiceHelp)
            // Says what a press does now, and the call's state beside it.
            .accessibilityLabel(voice.isActive ? "End voice conversation" : "Start voice conversation")
            .accessibilityValue(Text(stateWord))
            if let line = secondLine, !labels.iconOnly {
                Text(line.text).font(MacTheme.font(10.5))
                    .foregroundStyle(line.isError ? MacTheme.status(.error) : MacTheme.ink2)
                    .lineLimit(2).padding(.horizontal, 8).padding(.bottom, 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(labels.opacity)
                    .transition(.opacity)
            }
        }
    }

    /// On the rail the row's words move into its tooltip: the phase, then the
    /// line the row would have shown under it.
    private var voiceHelp: Text {
        let action: LocalizedStringKey = voice.phase == .idle ? "Start voice conversation" : "End voice conversation"
        guard labels.iconOnly else { return Text(action) }
        var tip = Text("Voice")
        if !companionEnabled || voice.phase != .idle { tip = tip + Text(" · ") + Text(stateWord) }
        if let line = secondLine { tip = tip + Text(" — ") + Text(line.text) }
        return tip
    }

    private var stateWord: LocalizedStringKey {
        if !companionEnabled { return "Off" }
        switch voice.phase {
        case .idle: return ""
        case .listening: return "Listening…"
        case .speaking: return "Speaking…"
        case .thinking: return "Thinking…"
        case .connecting: return "Connecting…"
        case .recovering: return "Recovering…"
        }
    }

    private var stateTint: Color { voice.phase == .idle ? MacTheme.ink3 : MacTheme.accent }

    private var secondLine: (text: String, isError: Bool)? {
        if let err = voice.errorText { return (err, true) }
        if let notice = voice.endNotice, voice.phase == .idle { return (notice, false) }
        if !voice.lastReply.isEmpty { return (voice.lastReply, false) }
        if !voice.lastUserText.isEmpty { return (voice.lastUserText, false) }
        if !companionEnabled {
            return voiceHintSeen ? nil : (String(localized: "Enable it in Settings › Voice, or tap the mic."), false)
        }
        if voice.phase == .connecting { return (String(localized: "Connecting — wait to speak"), false) }
        if voice.phase == .recovering { return (String(localized: "Recovering audio… tap the mic to end"), false) }
        let n = model.buddySessionIDs.count
        return (n == 0 ? String(localized: "Buddy: all sessions") : String(localized: "Buddy: \(n) selected"), false)
    }

    static func title(_ scope: DashboardSessionList.ProjectScope) -> String {
        switch scope {
        case .all: String(localized: "All projects")
        case .unknown: String(localized: "Unknown project (unassigned)")
        case .project(let name): name
        }
    }
}

// MARK: - Pieces

/// Cursor's sidebar row: a line glyph, the name, and on the right a count or a
/// shortcut in the mono face. Selection is a soft ink wash, never the accent.
struct SidebarRow: View {
    let systemName: String
    let title: LocalizedStringKey
    var count: Int = 0
    var countTint: Color = MacTheme.ink3
    var shortcut: String? = nil
    var selected = false
    let action: () -> Void
    @Environment(\.sidebarLabels) private var labels

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? MacTheme.accent : MacTheme.ink2).frame(width: 14)
                    .overlay(alignment: .topTrailing) {
                        // On the rail a count is a dot in its tint; the number is in the tooltip.
                        if labels.iconOnly, count > 0 {
                            Circle().fill(countTint).frame(width: 5, height: 5).offset(x: 2, y: -2)
                        }
                    }
                if !labels.iconOnly {
                    Group {
                        Text(title).font(MacTheme.font(12, .medium)).foregroundStyle(selected ? MacTheme.accentText : MacTheme.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        if count > 0 {
                            Text("\(count)").font(MacTheme.mono(10, .medium)).foregroundStyle(countTint)
                        } else if let shortcut {
                            Text(shortcut).font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                        }
                    }
                    .opacity(labels.opacity)
                    .transition(.opacity)
                }
            }
            .sidebarRowFrame()
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .help(labels.iconOnly ? railTip : Text(""))
        .accessibilityLabel(Text(title))
        .accessibilityCount(count)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The row's words, for the tooltip when only its glyph is on screen.
    private var railTip: Text {
        var tip = Text(title)
        if count > 0 { tip = tip + Text(" · \(count)") } else if let shortcut { tip = tip + Text("  \(shortcut)") }
        return tip
    }
}

/// A session group's heading, and the filter it stands for: "Needs you 1" in
/// the state's own tint. Clicking it narrows the column to that group (the
/// same scope ⌘1–⌘4 set) and clicking it again clears the filter.
struct GroupHeading: View {
    let filter: DashboardSessionList.StatusFilter
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(DashboardView.chipTitle(filter))
                    .font(MacTheme.font(10, .semibold)).textCase(.uppercase).kerning(0.5)
                    .foregroundStyle(tint)
                Text("\(count)").font(MacTheme.mono(9.5)).foregroundStyle(MacTheme.ink3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? Text("Show every group") : Text("Show only this group"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var tint: Color {
        switch filter {
        case .needsYou: MacTheme.status(.requiresInput)
        case .working: MacTheme.status(.thinking)
        case .done: MacTheme.status(.completeUnread)
        case .idle: MacTheme.ink3
        }
    }
}

/// One live session in the column: its state as a dot, its title, and under it
/// where it is running. Narrow by design — the reading itself has the whole
/// pane beside it, so the row only has to be findable.
struct AgentSessionRow: View {
    let session: AgentSession
    /// Under "All agents" the row says whose it is; inside one agent's column
    /// the mark would repeat on every row, so it is left off.
    let showAgent: Bool
    let selected: Bool
    let included: Bool
    let showInclude: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(MacTheme.status(session.presentationState))
                    .frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if showAgent {
                            SVGPathShape(session.agent.brandMark).fill(MacTheme.ink3)
                                .frame(width: 9, height: 9)
                        }
                        Text(session.displayTitle).font(MacTheme.font(12, selected ? .semibold : .medium))
                            .foregroundStyle(selected ? MacTheme.accentText : MacTheme.ink)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text(subtitle).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if showInclude, included {
                    Image(systemName: "waveform").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(MacTheme.accent).padding(.top, 3)
                }
                Text(session.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                    .lineLimit(1).padding(.top, 2)
            }
            .sidebarRowFrame(minHeight: 30, vertical: 5)
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .help(Text(session.displayTitle) + Text(" — ") + Text(subtitle))
        .accessibilityLabel(Text(session.displayTitle))
        // The 6pt dot is the only place the state is drawn, so it is said.
        .accessibilityValue(Text(verbatim: "\(session.presentationState.label), \(subtitle)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Where it is running: the checkout's own name, with the agent's in front
    /// of it while the column is showing every agent.
    private var subtitle: String {
        let scope = DashboardSessionList.ProjectScope.of(session)
        let name: String
        switch scope {
        case .all: name = String(localized: "All projects")
        case .unknown: name = String(localized: "Unknown project")
        case .project(let path):
            name = path.hasPrefix("/") ? URL(fileURLWithPath: path).lastPathComponent : path
        }
        return showAgent ? "\(session.agent.shortName) · \(name)" : name
    }
}

/// Section label in the mono face, uppercase and tracked, as Cursor sets
/// "Projects" and "Repositories".
struct SidebarHeading: View {
    let title: LocalizedStringKey
    @Environment(\.sidebarLabels) private var labels
    var body: some View {
        Text(title).font(MacTheme.mono(10, .medium)).foregroundStyle(MacTheme.ink3)
            .textCase(.uppercase).kerning(0.6).lineLimit(1)
            .opacity(labels.opacity)
            // The rail keeps the section break as a short hairline in the
            // heading's own frame, so the rows below never shift.
            .overlay {
                if labels.iconOnly {
                    Rectangle().fill(MacTheme.line).frame(width: 14, height: CompanionType.hairline)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The sidebar row's frame: one minimum height in both shapes (so nothing
    /// shifts as labels leave), 8 pt sides, the full column width, and the
    /// rounded hit shape `SidebarRowStyle` paints. Every row — glyph rows,
    /// session rows and the Voice row — takes it.
    func sidebarRowFrame(minHeight: CGFloat = 16, vertical: CGFloat = 5) -> some View {
        frame(minHeight: minHeight)
            .padding(.horizontal, 8).padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// A row's count as its accessibility value, only when it has one.
    @ViewBuilder func accessibilityCount(_ count: Int) -> some View {
        if count > 0 { accessibilityValue(Text("\(count)")) } else { self }
    }
}

/// Hover lifts the row a shade of ink; selection is the Settings sidebar's
/// green wash, so both windows mark "you are here" the same way.
struct SidebarRowStyle: ButtonStyle {
    var selected: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ground(configuration.isPressed), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
    }
    private func ground(_ pressed: Bool) -> Color {
        if selected { return MacTheme.accent.opacity(0.14) }
        if pressed { return MacTheme.ink.opacity(0.07) }
        return hovering ? MacTheme.ink.opacity(0.04) : .clear
    }
}

/// The mic as Cursor draws it in the composer: a 20pt disc, filled with the
/// accent while a conversation is live, quiet ground otherwise.
struct MicGlyph: View {
    let phase: VoiceChat.Phase
    let enabled: Bool
    var body: some View {
        Image(systemName: glyph)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(phase == .idle ? MacTheme.ink2 : MacTheme.bg)
            .frame(width: 20, height: 20)
            .background(phase == .idle ? MacTheme.bg3 : MacTheme.accent, in: Circle())
            .overlay(Circle().strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline))
    }
    private var glyph: String {
        if !enabled { return "mic.slash" }
        switch phase {
        case .idle: return "mic"
        case .listening: return "mic.fill"
        case .speaking: return "waveform"
        case .connecting, .recovering, .thinking: return "ellipsis"
        }
    }
}

/// Cursor's filter chip: outlined at rest, accent-filled when on.
struct FilterChip: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(MacTheme.font(10.5, .medium))
                .foregroundStyle(selected ? MacTheme.bg : MacTheme.ink2)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(selected ? MacTheme.accent : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? .clear : MacTheme.line, lineWidth: CompanionType.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The "iOS-vibebuddy ⌄" kind of dropdown pill Cursor uses for model and
/// project pickers: outlined, quiet, a chevron at the end.
struct MenuPill<Content: View>: View {
    let title: String
    /// True while the pill carries a non-default choice (a project filter),
    /// so the chosen value reads at a glance without a second chip row.
    var emphasized = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu(content: content) {
            HStack(spacing: 4) {
                Text(title).font(MacTheme.font(10.5, emphasized ? .semibold : .medium))
                    .foregroundStyle(emphasized ? MacTheme.accentText : MacTheme.ink2).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(MacTheme.ink3)
            }
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
    }
}

/// An empty pane that stays out of the way: a small glyph, a title at body
/// size and one line of guidance, centred, with no card behind it. Replaces
/// the system `ContentUnavailableView`, whose display-size title outweighed
/// the list beside it.
struct QuietEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var systemName = "sidebar.right"
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemName).font(.system(size: 22, weight: .light)).foregroundStyle(MacTheme.ink3)
                .padding(.bottom, 4)
            Text(title).font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
            Text(message).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}
