import SwiftUI
import VibeBuddyKit

/// Start a new task on the Mac from the phone. An editor, not a form: the
/// target (a directory the Mac has seen a session run in, and the agent) sits
/// on the editor's top edge as two chips, the prompt is the body, the
/// optional name and — for Cursor — the CLI's own options (model, plan/ask
/// mode, a fresh worktree) sit on its bottom edge. What "start" means for
/// each agent is one short line under the editor, with the long version
/// behind a disclosure. Claude Code runs as a `claude --bg` background
/// session, Codex as a daemon thread, Cursor as a `cursor-agent` conversation
/// vibebuddy hosts over ACP.
struct NewTaskSheet: View {
    @ObservedObject var dashboard: DashboardStore
    /// The paired Mac's name, for "Runs on <Mac>"; nil says "your Mac".
    var macName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind = .claudeCode
    @State private var directory = ""
    @State private var prompt: String
    @State private var name = ""
    @State private var busy = false
    @State private var pathExpanded = false
    @State private var explained = false
    /// The Mac's refusal, kept under the editor with the draft it refused.
    @State private var feedback: DashboardStore.DispatchFeedback?
    /// Cursor only. An empty model is the CLI's default; `agent` is the mode
    /// the CLI starts in when no `--mode` is given, so it travels as nil.
    @State private var cursorModel = ""
    @State private var cursorMode: CursorMode = .agent
    @State private var cursorWorktree = false
    @FocusState private var promptFocused: Bool

    /// `cursor-agent --mode` takes `plan` or `ask`; agent mode has no flag
    /// (cursor.com/docs/cli/reference/parameters).
    enum CursorMode: String, CaseIterable, Identifiable {
        case agent, plan, ask
        var id: String { rawValue }
        var label: String {
            switch self {
            case .agent: return "Agent"
            case .plan: return "Plan"
            case .ask: return "Ask"
            }
        }
        /// The wire value: nil for the default so an older Mac sees no change.
        var wireValue: String? { self == .agent ? nil : rawValue }
    }

    /// `initialPrompt` carries text typed into the dashboard's composer with
    /// no reply target — the composer's "new task" meaning lands here.
    init(dashboard: DashboardStore, macName: String? = nil, initialPrompt: String = "") {
        self.dashboard = dashboard
        self.macName = macName
        _prompt = State(initialValue: initialPrompt)
    }

    private var reachable: Bool { dashboard.state == .connected }
    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canStart: Bool { reachable && !busy && !directory.isEmpty && !trimmedPrompt.isEmpty }
    private var macLabel: String {
        let mac = macName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return mac.isEmpty ? String(localized: "your Mac") : mac
    }

    var body: some View {
        VStack(spacing: 0) {
            PhoneSheetHeader(title: String(localized: "New task"), close: { dismiss() }) {
                Button(busy ? "Starting…" : "Start") { start() }
                    .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.accent), size: .small))
                    .disabled(!canStart)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    editor
                    Text(runLine)
                        .font(CompanionType.font(11))
                        .foregroundStyle(CompanionPalette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let feedback, !feedback.started {
                        Label(feedback.message, systemImage: "exclamationmark.circle")
                            .font(CompanionType.font(12))
                            .foregroundStyle(CompanionPalette.status(.error))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !reachable {
                        PhoneNotice(symbol: "wifi.exclamationmark",
                                    text: String(localized: "Offline · the task can't start until \(macLabel) is reachable"),
                                    tint: CompanionPalette.status(.requiresInput))
                    }
                    DisclosureGroup(isExpanded: $explained) {
                        Text(explanation)
                            .font(CompanionType.font(12))
                            .foregroundStyle(CompanionPalette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    } label: {
                        Text("How this runs")
                            .font(CompanionType.font(12, .medium))
                            .foregroundStyle(CompanionPalette.ink2)
                    }
                    .tint(CompanionPalette.ink3)
                }
                .padding(.horizontal, PhoneMetrics.gutter)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(CompanionPalette.bg)
        .tint(CompanionPalette.accent)
        .onAppear {
            if directory.isEmpty { directory = dashboard.recentDirectories.first ?? "" }
            if !dashboard.dispatchAgents.contains(agent), let first = dashboard.dispatchAgents.first { agent = first }
        }
        .task {
            // The sheet is for typing; the keyboard comes up with it.
            try? await Task.sleep(for: .milliseconds(350))
            promptFocused = true
        }
    }

    // MARK: Editor

    /// Target chips on the top edge, the prompt as the body, the name and the
    /// agent's own options on the bottom edge — Cursor's editor shape.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                directoryChip
                agentChip
                Spacer(minLength: 0)
            }
            if !directory.isEmpty {
                // The full path on demand: one middle-truncated line that
                // opens out when tapped, so a deep path never owns the screen.
                Button { withAnimation(.smooth(duration: 0.15)) { pathExpanded.toggle() } } label: {
                    Text(directory)
                        .font(CompanionType.mono(10))
                        .foregroundStyle(CompanionPalette.ink3)
                        .lineLimit(pathExpanded ? nil : 1)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Directory path"))
                .accessibilityValue(directory)
                .accessibilityHint(pathExpanded ? "Collapse" : "Show the full path")
            }
            TextField(String(localized: "What should \(agent.displayName) do?"), text: $prompt, axis: .vertical)
                .font(CompanionType.font(15))
                .foregroundStyle(CompanionPalette.ink)
                .lineLimit(4...12)
                .focused($promptFocused)
                .padding(.vertical, 2)
            PhoneDivider()
            HStack(spacing: 8) {
                TextField(String(localized: "Name (optional)"), text: $name)
                    .font(CompanionType.font(12))
                    .foregroundStyle(CompanionPalette.ink2)
                Spacer(minLength: 0)
            }
            if agent == .cursor { cursorOptions }
        }
        .padding(12)
        .companionCard()
    }

    private var directoryChip: some View {
        Group {
            if dashboard.recentDirectories.isEmpty {
                chip("folder", String(localized: "No folder yet"), menu: false)
                    .accessibilityHint(String(localized: "Your Mac has not seen a session run yet."))
            } else {
                Menu {
                    Picker("Directory", selection: $directory) {
                        ForEach(dashboard.recentDirectories, id: \.self) { path in
                            Text((path as NSString).lastPathComponent).tag(path)
                        }
                    }
                } label: {
                    chip("folder", (directory as NSString).lastPathComponent, menu: true)
                }
                .accessibilityLabel(String(localized: "Directory"))
                .accessibilityValue((directory as NSString).lastPathComponent)
            }
        }
    }

    /// One agent is a label; several are a menu. The mark says which.
    private var agentChip: some View {
        Group {
            if dashboard.dispatchAgents.count > 1 {
                Menu {
                    Picker("Agent", selection: $agent) {
                        ForEach(dashboard.dispatchAgents, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                } label: {
                    chip(agent, agent.shortName, menu: true)
                }
                .accessibilityLabel(String(localized: "Agent"))
                .accessibilityValue(agent.displayName)
            } else {
                chip(agent, agent.shortName, menu: false)
            }
        }
    }

    /// Cursor's three launch choices as chips. The model list comes from the
    /// Mac's `cursor-agent --list-models`; when the Mac has none, the chip
    /// stays out and the CLI's default model is used.
    private var cursorOptions: some View {
        HStack(spacing: 6) {
            if !dashboard.cursorModels.isEmpty {
                Menu {
                    Picker("Model", selection: $cursorModel) {
                        Text("Default").tag("")
                        ForEach(dashboard.cursorModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                } label: {
                    chip("cpu", cursorModel.isEmpty ? String(localized: "Default model") : cursorModel, menu: true)
                }
                .accessibilityLabel(String(localized: "Model"))
            }
            Menu {
                Picker("Mode", selection: $cursorMode) {
                    ForEach(CursorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } label: {
                chip("slider.horizontal.3", cursorMode.label, menu: true)
            }
            .accessibilityLabel(String(localized: "Mode"))
            Button { cursorWorktree.toggle() } label: {
                Label(String(localized: "New worktree"), systemImage: cursorWorktree ? "checkmark" : "arrow.triangle.branch")
            }
            .buttonStyle(PhoneButtonStyle(kind: cursorWorktree ? .primary(CompanionPalette.accent) : .soft, size: .small))
            .accessibilityAddTraits(cursorWorktree ? .isSelected : [])
            Spacer(minLength: 0)
        }
    }

    private func chip(_ symbol: String, _ text: String, menu: Bool) -> some View {
        chipBody(text: text, menu: menu) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
        }
    }

    private func chip(_ agent: AgentKind, _ text: String, menu: Bool) -> some View {
        chipBody(text: text, menu: menu) { AgentMark(agent: agent, size: 12) }
    }

    /// A small soft key that names one part of the target: glyph, word,
    /// and a chevron when it opens a menu.
    private func chipBody<Icon: View>(text: String, menu: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 5) {
            icon()
            Text(text).lineLimit(1).truncationMode(.middle)
            if menu {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CompanionPalette.ink3)
            }
        }
        .font(CompanionType.font(12, .medium))
        .foregroundStyle(CompanionPalette.ink)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: PhoneMetrics.controlRadius, style: .continuous))
    }

    // MARK: Copy

    /// One line: where it runs and as what.
    private var runLine: String {
        switch agent {
        case .codex:
            return String(localized: "Runs on \(macLabel) as a Codex thread with your usual settings.")
        case .cursor:
            return String(localized: "Runs on \(macLabel) over the Cursor CLI, hosted by vibebuddy.")
        default:
            return String(localized: "Runs on \(macLabel) as a Claude Code background session.")
        }
    }

    private var explanation: String {
        switch agent {
        case .codex:
            return String(localized: "Runs as a new Codex thread on your Mac through the app-server daemon, with your usual model, approval and sandbox settings. It appears in Codex Desktop and in Working here.")
        case .cursor:
            return String(localized: "Hosted by vibebuddy on your Mac over the Cursor CLI. It appears in Working here and can be stopped, continued and answered from this phone; it ends if vibebuddy quits. A new worktree is created on your Mac under ~/.cursor/worktrees/<repo>/<name>; Plan and Ask are read-only.")
        default:
            return String(localized: "Runs as a Claude Code background session on your Mac (claude --bg) with your usual settings. It appears in Working here; Jump opens a terminal attached to it.")
        }
    }

    private func start() {
        guard canStart else { return }
        busy = true
        feedback = nil
        let cursor = agent == .cursor
        let request = DispatchRequest(agent: agent, cwd: directory,
                                      prompt: trimmedPrompt,
                                      name: name.isEmpty ? nil : name,
                                      model: cursor && !cursorModel.isEmpty ? cursorModel : nil,
                                      mode: cursor ? cursorMode.wireValue : nil,
                                      worktree: cursor && cursorWorktree ? true : nil)
        Task {
            let result = await dashboard.dispatch(request)
            busy = false
            if result.started { dismiss() } else { feedback = result }
        }
    }
}
