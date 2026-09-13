import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

// The dashboard's detail column in Cursor's shape (ticket 11): a title bar
// with the session's actions, a reading column that reads like a document
// with the composer pinned to its foot, and one right slot that is either
// the tool shelf, an opened tool pane, or a floating rail. `RightSlotState`
// decides which; the views only draw.

struct SessionDetailColumn: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @Binding var slot: RightSlotState
    /// This session's composer draft, owned by the dashboard (see
    /// `DashboardView.composerDrafts`).
    @Binding var draft: String
    /// Set by a manual read toggle so the auto-acknowledge does not undo it.
    @State private var acknowledgedBodyID: String?

    var body: some View {
        GeometryReader { geo in
            let layout = slot.layout(availableWidth: geo.size.width)
            let viewedSessionID: String? = {
                if case .full = layout { return nil }
                return session.id
            }()
            VStack(spacing: 0) {
                SessionTitleBar(session: session, model: model, slot: $slot, layout: layout,
                                acknowledgedBodyID: $acknowledgedBodyID)
                Rectangle().fill(MacTheme.line).frame(height: CompanionType.hairline)
                HStack(spacing: 0) {
                    if case .full = layout {} else {
                        ReadingColumn(session: session, model: model, draft: $draft, acknowledgedBodyID: $acknowledgedBodyID)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .topTrailing) {
                                if layout == .rail {
                                    ToolRail(slot: $slot).padding(.top, 10).padding(.trailing, 12)
                                }
                            }
                            .id(session.id)
                    }
                    switch layout {
                    case .shelf:
                        Rectangle().fill(MacTheme.line).frame(width: CompanionType.hairline)
                        ToolShelf(session: session, model: model, slot: $slot)
                            .frame(width: RightSlotState.shelfWidth)
                    case .pane(let width):
                        Rectangle().fill(MacTheme.line).frame(width: CompanionType.hairline)
                        ToolPane(session: session, model: model, slot: $slot, forcedFull: false)
                            .frame(width: width)
                    case .full(let forced):
                        ToolPane(session: session, model: model, slot: $slot, forcedFull: forced)
                            .frame(maxWidth: .infinity)
                    case .rail:
                        EmptyView()
                    }
                }
            }
            .onChange(of: viewedSessionID, initial: true) { _, id in
                model.dashboardViewedSessionID = id
            }
        }
        .background(MacTheme.bg)
        .onDisappear {
            if model.dashboardViewedSessionID == session.id {
                model.dashboardViewedSessionID = nil
            }
        }
    }
}

// MARK: - Title bar

/// Cursor's `IDE ↗ · ··· · sidebar` row over the conversation: the session's
/// whereabouts on the left, its actions on the right. Everything the session
/// can do that is not reading or deciding lives here, once.
private struct SessionTitleBar: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @Binding var slot: RightSlotState
    let layout: RightSlotState.Layout
    @Binding var acknowledgedBodyID: String?

    private var resultKey: String {
        (model.completionSourceID ?? "unknown") + "/" + session.id + "/" + (session.completionID ?? "working")
    }
    private var jumpTitle: LocalizedStringKey {
        session.agent == .grokBot ? "Open Grok Bot" : session.jumpsToDesktopThread ? "Open thread" : "Jump"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(session.project).font(MacTheme.mono(11)).foregroundStyle(MacTheme.ink2)
                .lineLimit(1).truncationMode(.middle)
            if let branch = session.branch, !branch.isEmpty {
                Text("·").foregroundStyle(MacTheme.ink3)
                Text(branch).font(MacTheme.mono(11)).foregroundStyle(MacTheme.ink3).lineLimit(1)
            }
            // A quiet mark for a session that is not at the default attention;
            // the setting itself is in the menu, the explanation in the tooltip.
            if let glyph = session.effectiveAttention.rowGlyph {
                Image(systemName: glyph).font(.system(size: 10, weight: .medium)).foregroundStyle(MacTheme.ink3)
                    .help(session.effectiveAttention.title + " · " + session.effectiveAttention.explanation)
                    .accessibilityLabel(session.effectiveAttention.title)
            }
            Spacer(minLength: 8)
            Button { model.jump(session) } label: {
                HStack(spacing: 3) {
                    Text(jumpTitle)
                    Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(TitleBarButtonStyle())
            .help("Jump to the agent's own window (⏎)")
            Menu {
                if session.status == .done, session.completionID != nil {
                    Button(session.hasUnreadCompletion ? "Mark as read" : "Mark as unread") {
                        acknowledgedBodyID = resultKey
                        if session.hasUnreadCompletion { model.acknowledge(session.id, displayedCompletionID: session.completionID) }
                        else { model.markUnread(session) }
                    }
                    Button("Replay this previous result") {
                        Task {
                            let body = await model.completionBody(for: session)
                            model.replayResult(session, body: body)
                        }
                    }
                    Divider()
                }
                Menu("Notifications") { AttentionPicker(session: session, model: model, style: .menu) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button).buttonStyle(TitleBarIconStyle()).menuIndicator(.hidden)
            .help("More actions")
            .accessibilityLabel("More actions")
            Button { slot = slot.reduced(.toggleRail) } label: {
                Image(systemName: layout == .rail ? "sidebar.trailing" : "sidebar.trailing")
                    .symbolVariant(layout == .rail ? .none : .fill)
            }
            .buttonStyle(TitleBarIconStyle())
            .help(layout == .rail ? "Show tools (⌥⌘B)" : "Hide tools (⌥⌘B)")
            .accessibilityLabel(layout == .rail ? "Show tools" : "Hide tools")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(MacTheme.bg)
    }
}

/// A quiet text key in the title bar: ink at rest, a wash on hover.
private struct TitleBarButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MacTheme.font(11.5, .medium)).foregroundStyle(MacTheme.ink2)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(hovering || configuration.isPressed ? MacTheme.ink.opacity(configuration.isPressed ? 0.07 : 0.04) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
    }
}

private struct TitleBarIconStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium)).foregroundStyle(MacTheme.ink2)
            .frame(width: 24, height: 24)
            .background(hovering || configuration.isPressed ? MacTheme.ink.opacity(configuration.isPressed ? 0.07 : 0.04) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
    }
}

// MARK: - Reading column

/// Reads like a document: the task, its state, the current result, the
/// decision it is waiting for. Records that are not the conversation
/// (changes, output excerpt, tool ledger) are in the right slot. The foot
/// holds either the composer or, while a request waits, its keys.
private struct ReadingColumn: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @Binding var draft: String
    @Binding var acknowledgedBodyID: String?
    @State private var completionBody: CompletionBody?
    @State private var resultIsVisible = false

    static let readingWidth: CGFloat = 680

    private var resultKey: String {
        (model.completionSourceID ?? "unknown") + "/" + session.id + "/" + (session.completionID ?? "working")
    }
    private var currentBody: CompletionBody? {
        guard let completionBody, completionBody.sourceID == model.completionSourceID, completionBody.sessionID == session.id,
              completionBody.completionID == session.completionID else { return nil }
        return completionBody
    }
    private var approvalKeysAtFoot: PendingApproval? {
        guard session.status == .needsResponse, let approval = session.pendingApproval,
              ApprovalEligibility.approval(for: session) != nil else { return nil }
        return approval
    }
    private var composerAtFoot: Bool {
        session.status != .needsResponse && SessionActionSupport.resolve(for: session).isAvailable
    }

    var body: some View {
        ScrollView {
            reading
                .frame(maxWidth: Self.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { foot }
        .animation(.smooth(duration: 0.18), value: model.jumpFeedback)
        .task(id: resultKey) {
            completionBody = nil
            resultIsVisible = false
            let key = resultKey
            let loaded = await model.completionBody(for: session)
            guard !Task.isCancelled, key == resultKey else { return }
            completionBody = loaded
        }
        .onChange(of: currentBody) { _, _ in acknowledgeVisibleBody() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in acknowledgeVisibleBody() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in acknowledgeVisibleBody() }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.taskGoal).lineLimit(3).font(MacTheme.font(20, .semibold)).foregroundStyle(MacTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: session.presentationState.symbolName).font(.system(size: 10, weight: .bold))
                Text(session.statusLabel)
            }
            .font(MacTheme.font(12, .heavy))
            .foregroundStyle(MacTheme.status(session.presentationState))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(MacTheme.status(session.presentationState).opacity(0.14), in: Capsule())

            Text(ToolActivity.label(for: session)).font(MacTheme.font(12, .medium))
                .foregroundStyle(MacTheme.ink2)
            if let progress = session.detailProgress, !progress.isEmpty {
                Text(progress).font(MacTheme.font(14)).foregroundStyle(MacTheme.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(session.detailProgressSource).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
            }
            if session.status == .done, session.completionID != nil {
                if let body = currentBody {
                    if let text = body.text {
                        Text(text).font(MacTheme.font(14)).foregroundStyle(MacTheme.ink)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .completionReadingVisibility { visible in
                                resultIsVisible = visible; acknowledgeVisibleBody()
                            }
                        Text("Agent final response · this completion · not independently verified")
                            .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
                    } else if let reason = body.unavailableReason {
                        Text(LocalizedStringKey(reason)).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
                    }
                } else { Text("Loading this completion…").font(MacTheme.font(11)) }
            }
            if session.status == .needsResponse {
                Text("Your decision").font(MacTheme.font(12, .semibold)).foregroundStyle(MacTheme.ink2)
                if let approval = session.pendingApproval {
                    // The keys sit at the foot while the request is decidable
                    // here; the request itself stays in the reading.
                    RequestCard(session: session, approval: approval, model: model, showsActions: approvalKeysAtFoot == nil)
                } else if let question = session.pendingQuestion {
                    if WaitHandling.resolve(for: session) == .remoteAvailable {
                        QuestionCardView(question: question) { answers in model.answer(session.id, answers: answers) }
                    } else {
                        Text(question.prompt).font(MacTheme.font(14)).foregroundStyle(MacTheme.ink)
                        Text(WaitHandling.resolve(for: session).message).font(MacTheme.font(11))
                    }
                } else {
                    Text(WaitHandling.resolve(for: session).message).font(MacTheme.font(11))
                }
            }
            if !composerAtFoot, let feedback = model.answerFeedback[session.id] {
                Text(feedback).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
            }
            // What the last jump actually achieved — focused the pane, only
            // raised the app, or found nothing to raise. Same wording as the
            // glance rows.
            if let outcome = model.jumpFeedback[session.id] {
                Label(outcome.macMessage(for: session), systemImage: "arrow.uturn.forward")
                    .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                    .contentTransition(.opacity)
            }
            HStack(spacing: 6) {
                if let m = session.model { Label(m, systemImage: "cpu") }
                if let observation = session.observationDescription {
                    Text("·"); Text(observation)
                    if let last = session.lastObservedAt { Text(last, style: .relative) }
                }
            }
            .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3)
        }
    }

    /// The foot is one thing at a time: the request's keys while a request
    /// waits and can be answered here, else the composer with its scope line.
    @ViewBuilder private var foot: some View {
        if let approval = approvalKeysAtFoot {
            footChrome {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { ApprovalActionRow(session: session, approval: approval, model: model) }
                    VStack(alignment: .leading, spacing: 8) { ApprovalActionRow(session: session, approval: approval, model: model) }
                }
            }
        } else if composerAtFoot {
            footChrome {
                VStack(alignment: .leading, spacing: 6) {
                    Text(scopeLine).font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3).lineLimit(1)
                    InstructionComposer(placeholder: session.status == .done ? "Start a new turn…" : "Add to the current turn…",
                                        externalDraft: $draft) { text in
                        model.answer(session.id, answers: [:], text: text)
                    }
                    if let feedback = model.answerFeedback[session.id] {
                        Text(feedback).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                    }
                }
            }
        }
    }

    private var scopeLine: String {
        [session.agent.displayName, session.model, session.branch].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func footChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(MacTheme.line).frame(height: CompanionType.hairline)
            content()
                .frame(maxWidth: Self.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.vertical, 10)
        }
        .background(MacTheme.bg)
    }

    private func acknowledgeVisibleBody() {
        guard resultIsVisible, currentBody?.text?.isEmpty == false, session.hasUnreadCompletion,
              acknowledgedBodyID != resultKey, model.isViewing(session.id), NSApp.isActive,
              NSApp.keyWindow?.identifier?.rawValue == "com.vibebuddy.dashboard" else { return }
        acknowledgedBodyID = resultKey
        model.acknowledge(session.id, displayedCompletionID: session.completionID)
    }
}

// MARK: - Request

/// Round 4, detail pane: the request as a card you can judge before answering —
/// who asks, what for, the diff or command. Its keys draw here only when the
/// column has no foot for them (`showsActions`).
struct RequestCard: View {
    let session: AgentSession
    let approval: PendingApproval
    @ObservedObject var model: MenuBarModel
    var showsActions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentAvatar(agent: session.agent)
                VStack(alignment: .leading, spacing: 1) {
                    (Text(session.project).fontWeight(.black) + Text(" wants to \(MacSummaryCopy.requestVerb(approval))"))
                        .font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
                    Text([approval.tool, session.summary].compactMap { $0 }.joined(separator: " · "))
                        .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3).lineLimit(1)
                }
            }
            ApprovalBody(approval: approval)
            if ApprovalEligibility.approval(for: session) == nil {
                // Capability does not establish whether the person is present.
                Label(WaitHandling.resolve(for: session).message, systemImage: "keyboard")
                    .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                if session.canJump {
                    Button(session.agent == .grokBot ? "Open Grok Bot" : session.jumpsToDesktopThread ? "Open thread" : "Jump ⏎") { model.jump(session) }
                        .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent)))
                }
            } else {
                if showsActions {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { ApprovalActionRow(session: session, approval: approval, model: model) }
                        VStack(alignment: .leading, spacing: 8) { ApprovalActionRow(session: session, approval: approval, model: model) }
                    }
                }
                if let rule = approval.suggestedRule {
                    Text("Always allow adds \(rule) to Claude's own permission rules — the same rule the terminal dialog offers.")
                        .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if session.agent == .grok, let mode = approval.permissionMode, mode != "bypassPermissions" {
                Label {
                    Text("Grok will still ask in the terminal after Allow (permission mode: \(mode)). Set permission_mode = \"always-approve\" to approve from here.")
                } icon: {
                    Image(systemName: "terminal")
                }
                .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
            }
        }
    }
}

/// `Approve ▾` and `Deny`, with their single-key shortcuts. Jump is in the
/// title bar, not repeated here.
struct ApprovalActionRow: View {
    let session: AgentSession
    let approval: PendingApproval
    @ObservedObject var model: MenuBarModel

    var body: some View {
        SplitApproveButton(
            approve: { model.decide(approval.id, .allow) },
            always: { model.decide(approval.id, .alwaysAllow) },
            session: { model.decide(approval.id, .allowSession) },
            allowsPersistentDecision: approval.canPersistDecision)
            .background { Button("") { model.decide(approval.id, .allow) }.keyboardShortcut("a", modifiers: []).opacity(0) }
        Button("Deny") { model.decide(approval.id, .deny) }
            .buttonStyle(PillButtonStyle(kind: .ghost))
            .keyboardShortcut("d", modifiers: [])
    }
}

// MARK: - Shelf

/// Cursor's `On <repo>` group: the tools this session's workspace offers,
/// each a row that opens its pane. Changes carries the added-line count as a
/// word in the accent, never a badge; an unreadable workspace shows `—`.
private struct ToolShelf: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @Binding var slot: RightSlotState
    @State private var count: Count = .loading

    private enum Count: Equatable { case loading, unknown(String), value(Int) }

    private var projectName: String {
        session.project.hasPrefix("/") ? URL(fileURLWithPath: session.project).lastPathComponent : session.project
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("On \(projectName)").font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
            ShelfRow(systemName: RightSlotState.Tool.changes.systemName, title: "Changes",
                     trailing: countWord, trailingTint: countTint, help: countHelp) { slot = slot.reduced(.open(.changes)) }
            ShelfRow(systemName: RightSlotState.Tool.output.systemName, title: "Output") { slot = slot.reduced(.open(.output)) }
            ShelfRow(systemName: RightSlotState.Tool.activity.systemName, title: "Activity") { slot = slot.reduced(.open(.activity)) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MacTheme.bg)
        .task(id: session.id) {
            count = .loading
            while !Task.isCancelled {
                let changes = await model.workspaceChanges(for: session, scope: .uncommitted, baseline: nil, file: nil)
                guard !Task.isCancelled else { return }
                if let added = changes.addedLineCount { count = .value(added) }
                else { count = .unknown(changes.unavailableReason ?? String(localized: "The change count could not be read.")) }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private var countWord: String? {
        switch count {
        case .loading: nil
        case .unknown: "—"
        case .value(let n): n > 0 ? "+\(n)" : nil
        }
    }
    private var countTint: Color {
        if case .value = count { return MacTheme.accent }
        return MacTheme.ink3
    }
    private var countHelp: String? {
        switch count {
        case .unknown(let reason): reason
        case .value(let n): n > 0 ? String(localized: "\(n) lines added in uncommitted tracked files") : String(localized: "No uncommitted changes")
        case .loading: nil
        }
    }
}

private struct ShelfRow: View {
    let systemName: String
    let title: LocalizedStringKey
    var trailing: String? = nil
    var trailingTint: Color = MacTheme.ink3
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MacTheme.ink2).frame(width: 14)
                Text(title).font(MacTheme.font(12, .medium)).foregroundStyle(MacTheme.ink).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(MacTheme.mono(10, .medium)).foregroundStyle(trailingTint)
                        .help(help ?? "")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(SidebarRowStyle(selected: false))
    }
}

extension RightSlotState.Tool {
    var title: LocalizedStringKey {
        switch self {
        case .changes: "Changes"
        case .output: "Output"
        case .activity: "Activity"
        }
    }
    var systemName: String {
        switch self {
        case .changes: "plus.forwardslash.minus"
        case .output: "text.alignleft"
        case .activity: "list.bullet.rectangle"
        }
    }
}

// MARK: - Rail

/// The slot collapsed: a small floating strip of the same tools at the top
/// right of the reading column. It takes no width, so the reading column
/// recentres under it.
private struct ToolRail: View {
    @Binding var slot: RightSlotState

    var body: some View {
        VStack(spacing: 2) {
            RailButton(systemName: "sidebar.trailing", help: "Show tools (⌥⌘B)") { slot = slot.reduced(.toggleRail) }
            Rectangle().fill(MacTheme.line).frame(width: 14, height: CompanionType.hairline).padding(.vertical, 2)
            ForEach(RightSlotState.Tool.allCases, id: \.self) { tool in
                RailButton(systemName: tool.systemName, help: tool.helpTitle) { slot = slot.reduced(.open(tool)) }
            }
        }
        .padding(4)
        .companionCard(MacTheme.bg3, radius: 8)
    }
}

private extension RightSlotState.Tool {
    var helpTitle: LocalizedStringKey {
        switch self {
        case .changes: "Open Changes"
        case .output: "Open Output"
        case .activity: "Open Activity"
        }
    }
}

private struct RailButton: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: systemName) }
            .buttonStyle(TitleBarIconStyle())
            .help(help)
            .accessibilityLabel(help)
    }
}

// MARK: - Pane

/// A tool opened in the slot's place: a tab strip to switch tools, expand
/// and close on the right. When the window could not fit the pane beside
/// the reading column it fills the column instead and leads with a way back.
private struct ToolPane: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @Binding var slot: RightSlotState
    let forcedFull: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if forcedFull {
                    Button { slot = slot.reduced(.close) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                            Text("Session")
                        }
                    }
                    .buttonStyle(TitleBarButtonStyle())
                    .help("Back to the session")
                    Rectangle().fill(MacTheme.line).frame(width: CompanionType.hairline, height: 14).padding(.horizontal, 4)
                }
                ForEach(RightSlotState.Tool.allCases, id: \.self) { tool in
                    PaneTab(tool: tool, selected: slot.tool == tool) { slot = slot.reduced(.select(tool)) }
                }
                Spacer(minLength: 4)
                if !forcedFull {
                    Button { slot = slot.reduced(.toggleExpanded) } label: {
                        Image(systemName: slot.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(TitleBarIconStyle())
                    .help(slot.expanded ? "Restore the reading column" : "Expand this tool")
                    .accessibilityLabel(slot.expanded ? "Collapse tool" : "Expand tool")
                }
                Button { slot = slot.reduced(.close) } label: { Image(systemName: "xmark") }
                    .buttonStyle(TitleBarIconStyle())
                    .help("Close this tool")
                    .accessibilityLabel("Close tool")
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            Rectangle().fill(MacTheme.line).frame(height: CompanionType.hairline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(session.id)
        }
        .background(MacTheme.bg)
    }

    @ViewBuilder private var content: some View {
        switch slot.tool {
        case .changes:
            WorkspaceChangesView(embedded: true) { scope, baseline, file in
                await model.workspaceChanges(for: session, scope: scope, baseline: baseline, file: file)
            }
        case .output:
            OutputPane(session: session, model: model)
        case .activity:
            ScrollView { ToolLedgerView(session: session).padding(16) }
        }
    }
}

/// Cursor's tab: a glyph and a word, on `bg2` when it is the one showing.
private struct PaneTab: View {
    let tool: RightSlotState.Tool
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tool.systemName).font(.system(size: 10, weight: .medium))
                Text(tool.title).font(MacTheme.font(11.5, .medium))
            }
            .foregroundStyle(selected ? MacTheme.ink : MacTheme.ink2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? MacTheme.bg2 : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Bounded live output; never described as full history. The pane's tab
/// names it, so the body leads with where it came from and how much it is.
private struct OutputPane: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @State private var output: RecentOutput?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    if let output {
                        Text(output.sourceLabel)
                        if let updatedAt = output.updatedAt {
                            Text("·"); Text(updatedAt, style: .relative).monospacedDigit()
                        }
                    }
                    Spacer()
                    Button("Refresh") { Task { await reload() } }
                        .buttonStyle(PillButtonStyle(kind: .ghost, size: .small)).disabled(loading)
                }
                .font(MacTheme.font(10, .semibold)).foregroundStyle(MacTheme.ink2)
                if let output {
                    if !output.statusLine.isEmpty {
                        Text(output.statusLine).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    }
                    Text("A limited recent excerpt. Open History to read indexed local conversations.")
                        .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
                    if output.entries.isEmpty {
                        QuietEmptyState(title: "No recent output", message: "No recent output is available from this source.",
                                        systemName: "text.alignleft")
                    }
                    ForEach(Array(output.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.role == "assistant" ? "Assistant" : "You")
                                .font(MacTheme.font(10, .semibold)).foregroundStyle(MacTheme.ink2)
                            Text(entry.text).font(MacTheme.font(13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else { ProgressView().controlSize(.small) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: session.id) { await reload() }
    }

    private func reload() async {
        loading = true
        output = await model.recentOutput(for: session.id)
        loading = false
    }
}
