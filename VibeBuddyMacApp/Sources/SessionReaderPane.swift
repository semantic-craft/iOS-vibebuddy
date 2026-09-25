import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeBuddyKit
import VibeBuddyMacCore

/// The dashboard's right column (ADR-0024): a two-line head with the session's
/// controls in its top-right corner (the jump, the view switch, the bell and
/// ···, all glyphs with tooltips), the conversation body, and a dock
/// at the bottom for the one decision or reply the session is waiting on.
struct SessionReaderPane: View {
    enum Tab: String, CaseIterable { case conversation, activity, changes }

    let subject: ReaderSubject
    let targetMessage: String?
    @ObservedObject var model: MenuBarModel
    @ObservedObject var reader: SessionReaderModel
    var draft: Binding<String>? = nil
    @State private var localDrafts: [String: String] = [:]
    @State private var acknowledgedBodyID: String?
    @State private var tab: Tab = .conversation
    @State private var exportError: String?

    private var live: AgentSession { subject.live }
    private var viewedSessionID: String? { tab == .conversation ? live.id : nil }
    private var composerDraft: Binding<String> {
        let key = (model.completionSourceID ?? "unknown") + "/" + subject.id
        return draft ?? Binding(get: { localDrafts[key] ?? "" }, set: { localDrafts[key] = $0.isEmpty ? nil : $0 })
    }

    /// Reloads on selection, on a target message, and on the live session's
    /// own turn boundaries. The file watcher covers appended text in between.
    private var loadKey: String {
        [subject.id, targetMessage ?? "", live.status.rawValue, "\(live.statusSince.timeIntervalSince1970)",
         live.activeTool ?? "", live.completionID ?? ""].joined(separator: "\u{1f}")
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
            if model.dashboardViewedSessionID == live.id { model.dashboardViewedSessionID = nil }
        }
        .onChange(of: subject.id) { _, _ in if tab != .conversation && !tabEnabled(tab) { tab = .conversation } }
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
            if live.status == .working, let progress = live.detailProgress, !progress.isEmpty {
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
        case .activity: return true
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
        if live.canJump {
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
        Menu { moreItems } label: { HeaderIcon(systemName: "ellipsis", tint: MacTheme.ink2) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("More actions for this session")
            .accessibilityLabel("More actions")
    }

    @ViewBuilder private var moreItems: some View {
        if SessionActionSupport.resolveStop(for: live).isAvailable {
            Button("Stop task") { model.stop(live) }
        }
        if live.status == .done, live.completionID != nil {
            Button(live.hasUnreadCompletion ? "Mark as read" : "Mark as unread") {
                acknowledgedBodyID = (model.completionSourceID ?? "unknown") + "/" + live.id + "/" + (live.completionID ?? "working")
                if live.hasUnreadCompletion { model.acknowledge(live.id, displayedCompletionID: live.completionID) }
                else { model.markUnread(live) }
            }
            Button("Replay this previous result") { model.replayResult(live) }
        }
        if let transcript = reader.transcript {
            Divider()
            Button("Export Markdown…") { export(transcript) }.disabled(reader.loading || reader.error != nil)
            Button("Show source") { showSource(transcript) }
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
                HStack(spacing: 5) {
                    Circle().fill(MacTheme.status(live.presentationState)).frame(width: 7, height: 7)
                    Text(ToolActivity.label(for: live)).fontWeight(.semibold)
                        .foregroundStyle(MacTheme.status(live.presentationState))
                }.lineLimit(1)
                if let m = live.model { dot; Text(m).lineLimit(1) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if let observation = live.observationDescription {
                    HStack(spacing: 4) {
                        Text(observation)
                        if let last = live.lastObservedAt { Text(last, style: .relative) }
                    }.lineLimit(1)
                    if sourceLabel != nil { dot }
                }
                if let source = sourceLabel { source.lineLimit(1) }
                if let warnings = reader.transcript?.warnings, !warnings.isEmpty {
                    Image(systemName: "info.circle").foregroundStyle(MacTheme.ink3)
                        .help(warnings.joined(separator: "\n"))
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
        case .transcript(_, let updatedAt, _):
            return Text("Transcript · updated ") + Text(updatedAt, style: .relative)
        case .recentOutput(let label, _, _):
            return Text("Recent output · \(label) · limited excerpt")
        case .empty:
            return nil
        }
    }

    private func jumpHelp(_ live: AgentSession, _ destination: JumpDestination) -> String {
        if live.jumpsToDesktopThread { return String(localized: "\(destination.title) ⏎ — opens this thread.") }
        switch destination.symbol {
        case "terminal": return String(localized: "\(destination.title) ⏎ — focuses the pane this session runs in.")
        default: return String(localized: "\(destination.title) ⏎ — brings the app forward; the exact window is not addressable.")
        }
    }

    /// What the last jump achieved.
    private var jumpLine: String? {
        model.jumpFeedback[live.id]?.macMessage(for: live)
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
        } else {
            SessionReaderView(rows: reader.rows, targetMessage: targetMessage, note: bodyNote) {
                EmptyView()
            } tail: {
                if live.status == .done, live.completionID != nil {
                    ReaderResultCard(session: live, model: model, acknowledgedBodyID: $acknowledgedBodyID)
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
        case .transcript, .empty:
            return nil
        }
    }

    @ViewBuilder private var activity: some View {
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
    }

    @ViewBuilder private var changes: some View {
        if projectDirectoryExists {
            WorkspaceChangesView(embedded: true) { [live] scope, baseline, file in
                await model.workspaceChanges(for: live, scope: scope, baseline: baseline, file: file)
            }
            .id(subject.id)
        } else {
            QuietEmptyState(title: "Project directory unavailable", message: "Workspace changes read the project directory, which is not on this Mac.", systemName: "folder.badge.questionmark")
        }
    }

    // MARK: Dock

    private var hasDock: Bool {
        live.status == .needsResponse || SessionActionSupport.resolve(for: live).isAvailable
            || model.answerFeedback[live.id] != nil
    }

    /// Sized to its content; only past 340pt does it scroll inside, so a long
    /// approval never pushes the transcript off the pane. Its blocks stop at
    /// the same 760pt the transcript above stops at, so a wide pane does not
    /// stretch the diff across the window while the reading stays narrow.
    private var dock: some View {
        ViewThatFits(in: .vertical) {
            dockColumn
            ScrollView { dockColumn }.frame(maxHeight: 340)
        }
        .background(MacTheme.bg)
    }

    private var dockColumn: some View {
        dockContent.frame(maxWidth: 760, alignment: .leading).padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var dockContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if live.status == .needsResponse {
                Text("Your decision").font(MacTheme.font(12, .semibold)).foregroundStyle(MacTheme.ink2)
                    .accessibilityAddTraits(.isHeader)
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
        // A decision that appears under the reader, and the word on an answer
        // sent from it, are spoken: neither takes VoiceOver's focus.
        // Keyed by the session too: the pane is reused when the selection
        // moves, and arrowing through the sidebar must not speak every row.
        .onChange(of: [live.id, live.pendingApproval?.id ?? live.pendingQuestion?.id ?? ""]) { old, new in
            guard old[0] == new[0], !new[1].isEmpty, live.status == .needsResponse else { return }
            AccessibilityNotification.Announcement(String(localized: "Your decision")).post()
        }
        .onChange(of: [live.id, model.answerFeedback[live.id] ?? ""]) { old, new in
            guard old[0] == new[0], !new[1].isEmpty else { return }
            AccessibilityNotification.Announcement(new[1]).post()
        }
    }

    // MARK: Actions

    private func showSource(_ session: SessionHistorySession) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.sourcePath)])
    }

    private func export(_ session: SessionHistorySession) {
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
    @StateObject private var resultReader = CompletionBodyReader()
    @State private var resultAttempt = 0
    @State private var resultIsVisible = false
    @Binding var acknowledgedBodyID: String?

    private var resultKey: String { (model.completionSourceID ?? "unknown") + "/" + session.id + "/" + (session.completionID ?? "working") }
    private var resultRefresh: CompletionBodyRefresh {
        // Local result reads can finish while inactive; acknowledgement still requires foreground visibility.
        CompletionBodyRefresh(sourceID: model.completionSourceID, session: session, attempt: resultAttempt)
    }
    private var currentBody: CompletionBody? { resultReader.body(for: resultRefresh) }

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
            } else if resultReader.state(for: resultRefresh) == .failed {
                Text("Couldn’t load this result. Try again.").font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
            } else {
                Text("Loading this completion…").font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
            }
            if currentBody?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               resultReader.state(for: resultRefresh) != .loading {
                Button("Retry") { resultAttempt += 1 }
                    .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
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
        .task(id: resultRefresh) {
            if currentBody?.text?.isEmpty != false { resultIsVisible = false }
            await resultReader.load(resultRefresh) { await model.completionBody(for: session) }
        }
        .onChange(of: currentBody) { _, _ in acknowledgeVisibleBody() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            resultAttempt += 1
            acknowledgeVisibleBody()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            resultAttempt += 1
            acknowledgeVisibleBody()
        }
    }

    private func acknowledgeVisibleBody() {
        guard resultIsVisible, currentBody?.text?.isEmpty == false, session.hasUnreadCompletion,
              acknowledgedBodyID != resultKey, model.isViewing(session.id), NSApp.isActive,
              NSApp.keyWindow?.identifier?.rawValue == "com.vibebuddy.dashboard" else { return }
        acknowledgedBodyID = resultKey
        model.acknowledge(session.id, displayedCompletionID: session.completionID)
    }
}
