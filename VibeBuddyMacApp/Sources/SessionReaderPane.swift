import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeBuddyKit
import VibeBuddyMacCore

/// The dashboard's right column (ADR-0024): a two-line head with the session's
/// controls in its top-right corner (the jump, the view switch, the bell, the
/// star and ···, all glyphs with tooltips), the conversation body, and a dock
/// at the bottom for the one decision or reply the session is waiting on. The same pane reads a live session and a history record; what
/// differs is which controls the subject actually supports.
struct SessionReaderPane: View {
    enum Tab: String, CaseIterable { case conversation, activity, changes }

    let subject: ReaderSubject
    let targetMessage: String?
    @ObservedObject var model: MenuBarModel
    @ObservedObject var history: HistoryLibraryModel
    @ObservedObject var reader: SessionReaderModel
    var draft: Binding<String>? = nil
    @State private var localDrafts: [String: String] = [:]
    @State private var acknowledgedBodyID: String?
    @State private var tab: Tab = .conversation
    @State private var feedback: String?
    @State private var exportError: String?

    private var live: AgentSession? { subject.live }
    private var record: SessionHistorySession? { subject.record }
    private var viewedSessionID: String? { tab == .conversation ? live?.id : nil }
    private var composerDraft: Binding<String> {
        let key = (model.completionSourceID ?? "unknown") + "/" + subject.id
        return draft ?? Binding(get: { localDrafts[key] ?? "" }, set: { localDrafts[key] = $0.isEmpty ? nil : $0 })
    }

    /// Reloads on selection, on a search target, when the record's source
    /// moved, and on the live session's own turn boundaries. The file watcher
    /// covers appended text in between.
    private var loadKey: String {
        [subject.id, targetMessage ?? "", record?.sourcePath ?? "", record?.sourceRevision ?? "",
         record.map { "\($0.updatedAt.timeIntervalSince1970)|\($0.isAvailable)" } ?? "",
         live?.status.rawValue ?? "", live.map { "\($0.statusSince.timeIntervalSince1970)" } ?? "",
         live?.activeTool ?? "", live?.completionID ?? ""].joined(separator: "\u{1f}")
    }

    private var projectDirectoryExists: Bool {
        guard let path = subject.projectPath else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if hasDock {
                Divider()
                dock
            }
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        .task(id: loadKey) { await reader.load(subject, target: targetMessage) }
        .onChange(of: viewedSessionID, initial: true) { _, id in model.dashboardViewedSessionID = id }
        .onDisappear {
            if model.dashboardViewedSessionID == live?.id { model.dashboardViewedSessionID = nil }
        }
        .onChange(of: subject.id) { _, _ in feedback = nil; if tab != .conversation && !tabEnabled(tab) { tab = .conversation } }
        .alert("Could not export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    // MARK: Head

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 12) {
                title.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) { jumpControl; tabPicker; iconControls }.fixedSize()
            }
            metaRow
            if let line = jumpLine {
                Text(line).font(MacTheme.font(10.5)).foregroundStyle(MacTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true).contentTransition(.opacity)
            }
            if let live, live.status == .working, let progress = live.detailProgress, !progress.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(progress).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink).lineLimit(2).help(progress)
                    Text(live.detailProgressSource).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3).lineLimit(1)
                }
            }
        }
        .animation(.smooth(duration: 0.18), value: model.jumpFeedback)
    }

    private var title: some View {
        Text(subject.title).font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .help(subject.title)
    }

    /// Three glyphs with tooltips, the Cursor way; the words live in the help
    /// text and the accessibility label.
    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { candidate in
                let enabled = tabEnabled(candidate)
                Button {
                    tab = candidate
                } label: {
                    Image(systemName: symbol(for: candidate)).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tab == candidate ? MacTheme.bg : enabled ? MacTheme.ink2 : MacTheme.ink3)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(tab == candidate ? MacTheme.ink : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(help(for: candidate, enabled: enabled))
                .accessibilityLabel(Text(title(for: candidate)))
                .accessibilityAddTraits(tab == candidate ? .isSelected : [])
            }
        }
        .padding(1)
        .background(MacTheme.bg3, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reader view")
    }

    private func tabEnabled(_ tab: Tab) -> Bool {
        switch tab {
        case .conversation: return true
        case .activity: return live != nil
        case .changes: return projectDirectoryExists
        }
    }
    private func title(for tab: Tab) -> LocalizedStringKey {
        switch tab { case .conversation: "Conversation"; case .activity: "Activity"; case .changes: "Changes" }
    }
    private func symbol(for tab: Tab) -> String {
        switch tab { case .conversation: "text.alignleft"; case .activity: "wrench.and.screwdriver"; case .changes: "plus.forwardslash.minus" }
    }
    private func help(for tab: Tab, enabled: Bool) -> LocalizedStringKey {
        switch (tab, enabled) {
        case (.conversation, _): "The conversation as the agent's local transcript records it"
        case (.activity, true): "Observed tool calls and evidence for this live session"
        case (.activity, false): "No live activity for this record"
        case (.changes, true): "Read-only Git differences in the project directory"
        case (.changes, false): "The project directory is unavailable"
        }
    }

    /// The jump as one accent glyph: terminal, desktop thread or host app.
    /// ⏎ on the dashboard does the same; the tooltip names where it lands.
    @ViewBuilder private var jumpControl: some View {
        if let live, live.canJump {
            let destination = JumpDestination.resolve(live)
            Button { model.jump(live) } label: {
                HeaderIcon(systemName: destination.symbol, tint: MacTheme.accentText)
            }
            .buttonStyle(.plain)
            .help(Text(jumpHelp(live, destination)))
            .accessibilityLabel(Text(destination.title))
        }
    }

    @ViewBuilder private var iconControls: some View {
        if let live {
            Menu {
                AttentionPicker(session: live, model: model, style: .menu)
                Divider()
                Text(live.attentionOverride == nil
                     ? String(localized: "Automatic: \(live.effectiveAttention.title.lowercased()) — followed while you're driving it, normal otherwise.")
                     : live.effectiveAttention.explanation)
            } label: {
                HeaderIcon(systemName: live.effectiveAttention.symbol, tint: live.attentionOverride == nil ? MacTheme.ink2 : MacTheme.accentText)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Notifications for this session")
            .accessibilityLabel("Notifications")
        }
        if let record {
            Button { Task { await history.toggleFavorite(record) } } label: {
                HeaderIcon(systemName: record.isFavorite ? "star.fill" : "star",
                           tint: record.isFavorite ? MacTheme.status(.requiresInput) : MacTheme.ink2)
            }
            .buttonStyle(.plain)
            .help(record.isFavorite ? "Unfavorite" : "Favorite")
            .accessibilityLabel(record.isFavorite ? "Unfavorite" : "Favorite")
        }
        Menu { moreItems } label: { HeaderIcon(systemName: "ellipsis", tint: MacTheme.ink2) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("More actions for this session")
            .accessibilityLabel("More actions")
    }

    @ViewBuilder private var moreItems: some View {
        if let live {
            if live.status == .done, live.completionID != nil {
                Button(live.hasUnreadCompletion ? "Mark as read" : "Mark as unread") {
                    acknowledgedBodyID = (model.completionSourceID ?? "unknown") + "/" + live.id + "/" + (live.completionID ?? "working")
                    if live.hasUnreadCompletion { model.acknowledge(live.id, displayedCompletionID: live.completionID) }
                    else { model.markUnread(live) }
                }
                Button("Replay this previous result") { model.replayResult(live) }
            }
        }
        if let record {
            if subject.origin == .history, record.agent.supportsTranscript, !history.isDemo {
                Button(history.summary == nil ? "Generate summary" : "Regenerate summary") { history.generateSummary() }
                    .disabled(history.reading || history.summarizing)
            }
            Divider()
            Button(record.isPinned == true ? "Unpin" : "Pin") { Task { await history.togglePinned(record) } }
            Button(record.archivedLocally == true ? "Unarchive in library" : "Archive in library") {
                Task { await history.toggleArchive(record) }
            }
            Divider()
            Button("Export Markdown…") { export(record) }.disabled(!canExport)
            Button("Show source") { showSource(record) }.disabled(!record.isAvailable)
            if live == nil, HistorySessionSupport.resumeCommand(for: record) != nil {
                Button("Copy resume command") { copyResumeCommand(record) }
            }
        }
        Divider()
        Button("Refresh transcript") { reader.refresh() }
    }

    /// Identity and state on one line, evidence and body source on the next:
    /// two short lines truncate less than one long one at 340pt.
    private var metaRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                AgentBadge(agent: subject.agent)
                dot
                Text(subject.projectName).lineLimit(1).truncationMode(.middle)
                    .help(subject.projectPath ?? subject.projectName)
                dot
                if let live {
                    HStack(spacing: 5) {
                        Circle().fill(MacTheme.status(live.presentationState)).frame(width: 7, height: 7)
                        Text(ToolActivity.label(for: live)).fontWeight(.semibold)
                            .foregroundStyle(MacTheme.status(live.presentationState))
                    }.lineLimit(1)
                    if let m = live.model { dot; Text(m).lineLimit(1) }
                } else {
                    HStack(spacing: 5) {
                        Circle().strokeBorder(MacTheme.status(.idle), lineWidth: 1.5).frame(width: 7, height: 7)
                        Text("No live status").fontWeight(.semibold).foregroundStyle(MacTheme.ink3)
                    }.lineLimit(1)
                    if let record { dot; Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened)).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if let live, let observation = live.observationDescription {
                    HStack(spacing: 4) {
                        Text(observation)
                        if let last = live.lastObservedAt { Text(last, style: .relative) }
                    }.lineLimit(1)
                    if sourceLabel != nil { dot }
                }
                if let source = sourceLabel { source.lineLimit(1) }
                if let record, !record.warnings.isEmpty {
                    Image(systemName: "info.circle").foregroundStyle(MacTheme.ink3)
                        .help(record.warnings.joined(separator: "\n"))
                        .accessibilityLabel("Record notices")
                }
                Spacer(minLength: 0)
            }
        }
        .font(MacTheme.font(10.5)).foregroundStyle(MacTheme.ink2)
    }

    private var dot: some View { Text("·").foregroundStyle(MacTheme.ink3) }

    /// Where the body came from, so a bounded excerpt is never mistaken for
    /// the transcript and an archived transcript never for live evidence.
    private var sourceLabel: Text? {
        switch reader.body {
        case .transcript(_, let updatedAt, _, _):
            return Text("Transcript · updated ") + Text(updatedAt, style: .relative)
        case .recentOutput(let label, _, _):
            return Text("Recent output · \(label) · limited excerpt")
        case .empty, .unsupported:
            return nil
        }
    }

    private func jumpHelp(_ live: AgentSession, _ destination: JumpDestination) -> String {
        if live.agent == .grokBot { return String(localized: "Open Grok Bot ⏎ — brings the app forward; it does not locate this conversation.") }
        if live.jumpsToDesktopThread { return String(localized: "\(destination.title) ⏎ — opens this thread.") }
        switch destination.symbol {
        case "terminal": return String(localized: "\(destination.title) ⏎ — focuses the pane this session runs in.")
        default: return String(localized: "\(destination.title) ⏎ — brings the app forward; the exact window is not addressable.")
        }
    }

    /// What the last jump or copy achieved, or why neither is available.
    private var jumpLine: String? {
        if let live, let outcome = model.jumpFeedback[live.id] { return outcome.macMessage(for: live) }
        if let feedback { return feedback }
        if live == nil, let record, HistorySessionSupport.resumeCommand(for: record) == nil {
            return HistorySessionSupport.unavailableReason(for: record)
        }
        return nil
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        switch tab {
        case .conversation: conversation
        case .activity: activity
        case .changes: changes
        }
    }

    @ViewBuilder private var conversation: some View {
        if reader.loading && reader.rows.isEmpty {
            ProgressView("Reading conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = reader.error {
            VStack(spacing: 12) {
                Text(error).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                Button("Retry") { reader.refresh() }.buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .unsupported(let reason) = reader.body, reader.rows.isEmpty {
            QuietEmptyState(title: "Full transcript unavailable", message: LocalizedStringKey(reason), systemName: "text.book.closed")
        } else {
            VStack(spacing: 0) {
                if subject.origin == .history, let record, record.agent.supportsTranscript, !history.isDemo {
                    HistorySummaryView(history: history, session: record)
                        .companionCard(MacTheme.bg3)
                        .padding(12)
                    Divider()
                }
                SessionReaderView(rows: reader.rows, targetMessage: targetMessage, note: bodyNote) {
                    EmptyView()
                } tail: {
                    if let live, live.status == .done, live.completionID != nil {
                        ReaderResultCard(session: live, model: model, acknowledgedBodyID: $acknowledgedBodyID)
                    }
                }
            }
            .id(subject.id)
        }
    }

    private var bodyNote: String? {
        switch reader.body {
        case .recentOutput(let label, let status, _):
            let excerpt = String(localized: "A limited recent excerpt from \(label); this source keeps no readable transcript.")
            return status.isEmpty ? excerpt : excerpt + " " + status
        case .transcript(_, _, _, let isAvailable):
            return isAvailable ? nil : String(localized: "The source is unavailable. Showing the last indexed copy.")
        case .empty, .unsupported:
            return nil
        }
    }

    @ViewBuilder private var activity: some View {
        if let live {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        if let m = live.model { Label(m, systemImage: "cpu") }
                        if let observation = live.observationDescription {
                            Text("·"); Text(observation)
                            if let last = live.lastObservedAt { Text(last, style: .relative) }
                        }
                    }
                    .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3)
                    if let warning = RowPresentation(session: live).observationWarning {
                        Text(warning).font(MacTheme.font(11)).foregroundStyle(MacTheme.status(.requiresInput))
                    }
                    if let child = ToolActivity.childSummary(for: live) {
                        Text(child).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                    }
                    ToolLedgerView(session: live)
                }
                .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } else {
            QuietEmptyState(title: "No live activity", message: "This record has no observed tool calls.", systemName: "wrench.and.screwdriver")
        }
    }

    @ViewBuilder private var changes: some View {
        if let path = subject.projectPath, projectDirectoryExists {
            WorkspaceChangesView(embedded: true) { scope, baseline, file in
                if let live {
                    return await model.workspaceChanges(for: live, scope: scope, baseline: baseline, file: file)
                }
                return await Task.detached(priority: .utility) {
                    WorkspaceChangesReader.read(cwd: path, scope: scope, baseline: baseline, file: file, shared: false)
                }.value
            }
            .id(subject.id)
        } else {
            QuietEmptyState(title: "Project directory unavailable", message: "Workspace changes read the project directory, which is not on this Mac.", systemName: "folder.badge.questionmark")
        }
    }

    // MARK: Dock

    private var hasDock: Bool {
        guard let live else { return false }
        return live.status == .needsResponse || SessionActionSupport.resolve(for: live).isAvailable
            || model.answerFeedback[live.id] != nil
    }

    /// Sized to its content; only past 340pt does it scroll inside, so a long
    /// approval never pushes the transcript off the pane.
    private var dock: some View {
        ViewThatFits(in: .vertical) {
            dockContent.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView { dockContent.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 340)
        }
        .background(MacTheme.bg)
    }

    @ViewBuilder private var dockContent: some View {
        if let live {
            VStack(alignment: .leading, spacing: 10) {
                if live.status == .needsResponse {
                    Text("Your decision").font(MacTheme.font(12, .semibold)).foregroundStyle(MacTheme.ink2)
                    if let approval = live.pendingApproval {
                        RequestCard(session: live, approval: approval, model: model)
                    } else if let question = live.pendingQuestion {
                        if WaitHandling.resolve(for: live) == .remoteAvailable {
                            QuestionCardView(question: question) { answers in model.answer(live.id, answers: answers) }
                        } else {
                            Text(question.prompt).font(MacTheme.font(14)).foregroundStyle(MacTheme.ink)
                            Text(WaitHandling.resolve(for: live).message).font(MacTheme.font(11))
                        }
                    } else {
                        Text(WaitHandling.resolve(for: live).message).font(MacTheme.font(11))
                    }
                } else if SessionActionSupport.resolve(for: live).isAvailable {
                    InstructionComposer(placeholder: live.status == .done ? "Start a new turn…" : "Add to the current turn…", externalDraft: composerDraft) { text in
                        model.answer(live.id, answers: [:], text: text)
                    }
                    .id(live.id + String(live.statusSince.timeIntervalSince1970))
                }
                if let feedback = model.answerFeedback[live.id] {
                    Text(feedback).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                }
            }
        }
    }

    // MARK: Actions

    private var canExport: Bool {
        guard let record, record.agent.supportsTranscript else { return false }
        return !reader.loading && reader.error == nil && reader.transcript?.id == record.id
            && reader.transcript?.sourcePath == record.sourcePath
    }

    private func showSource(_ record: SessionHistorySession) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.sourcePath)])
    }

    private func copyResumeCommand(_ record: SessionHistorySession) {
        feedback = HistorySessionSupport.copyResumeCommand(for: record)
            ? String(localized: "Resume command copied. Run it in your terminal to continue.")
            : String(localized: "The resume command is no longer available.")
    }

    private func export(_ record: SessionHistorySession) {
        guard let session = reader.transcript, session.id == record.id,
              session.sourcePath == record.sourcePath else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(session.agent.rawValue)-\(session.nativeSessionID).md"
        panel.canCreateDirectories = true
        if let root = E2ERunConfiguration.current?.root { panel.directoryURL = root }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try SessionHistoryExport.markdown(session: session).write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = error.localizedDescription }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

/// The 24-point hairline square the head's bell, star and ··· share.
private struct HeaderIcon: View {
    let systemName: String
    let tint: Color
    var body: some View {
        Image(systemName: systemName).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(MacTheme.bg3, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline))
            .contentShape(Rectangle())
    }
}

/// The daemon's result for this exact source/session/completion, at the end
/// of the transcript. It is the one thing in the reader whose foreground
/// visibility confirms a read (ADR-0020); the transcript's own last message,
/// even when it says the same words, never does.
struct ReaderResultCard: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @State private var completionBody: CompletionBody?
    @State private var resultIsVisible = false
    @Binding var acknowledgedBodyID: String?

    private var resultKey: String { (model.completionSourceID ?? "unknown") + "/" + session.id + "/" + (session.completionID ?? "working") }
    private var currentBody: CompletionBody? {
        guard let completionBody, completionBody.sourceID == model.completionSourceID, completionBody.sessionID == session.id,
              completionBody.completionID == session.completionID else { return nil }
        return completionBody
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Result · this completion").font(MacTheme.font(10.5, .semibold)).foregroundStyle(MacTheme.ink3)
                Spacer()
                if session.hasUnreadCompletion {
                    Text("Unread").font(MacTheme.font(10.5, .semibold)).foregroundStyle(MacTheme.accentText)
                }
            }
            if let body = currentBody {
                if let text = body.text {
                    Text(text).font(MacTheme.font(13)).foregroundStyle(MacTheme.ink)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .completionReadingVisibility { visible in
                            resultIsVisible = visible; acknowledgeVisibleBody()
                        }
                    Text("Agent final response · this completion · not independently verified")
                        .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
                } else if let reason = body.unavailableReason {
                    Text(LocalizedStringKey(reason)).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
                }
            } else {
                Text("Loading this completion…").font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
            }
            HStack(spacing: 6) {
                Button(session.hasUnreadCompletion ? "Mark as read" : "Mark as unread") {
                    acknowledgedBodyID = resultKey
                    if session.hasUnreadCompletion { model.acknowledge(session.id, displayedCompletionID: session.completionID) }
                    else { model.markUnread(session) }
                }.buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
                Button("Replay this result") { model.replayResult(session, body: currentBody) }
                    .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
            }
        }
        .padding(14)
        .frame(maxWidth: 720, alignment: .leading)
        .background(MacTheme.bg3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline))
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

    private func acknowledgeVisibleBody() {
        guard resultIsVisible, currentBody?.text?.isEmpty == false, session.hasUnreadCompletion,
              acknowledgedBodyID != resultKey, model.isViewing(session.id), NSApp.isActive,
              NSApp.keyWindow?.identifier?.rawValue == "com.vibebuddy.dashboard" else { return }
        acknowledgedBodyID = resultKey
        model.acknowledge(session.id, displayedCompletionID: session.completionID)
    }
}
