import SwiftUI
import VibeBuddyKit

/// Start a new task on the Mac from the phone: a directory the Mac has seen a
/// session run in, the agent, the prompt, an optional name. Claude Code runs
/// as a `claude --bg` background session, Codex as a daemon thread, Cursor as
/// a `cursor-agent` conversation vibebuddy hosts over ACP — for which the
/// CLI's own global options (model, plan/ask mode, a fresh worktree) are
/// offered too.
struct NewTaskSheet: View {
    @ObservedObject var dashboard: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind = .claudeCode
    @State private var directory = ""
    @State private var prompt: String
    @State private var name = ""
    @State private var busy = false
    /// Cursor only. An empty model is the CLI's default; `agent` is the mode
    /// the CLI starts in when no `--mode` is given, so it travels as nil.
    @State private var cursorModel = ""
    @State private var cursorMode: CursorMode = .agent
    @State private var cursorWorktree = false

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
    init(dashboard: DashboardStore, initialPrompt: String = "") {
        self.dashboard = dashboard
        _prompt = State(initialValue: initialPrompt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Where") {
                    if dashboard.recentDirectories.isEmpty {
                        Text("Your Mac has not seen a session run yet.").foregroundStyle(.secondary)
                    } else {
                        Picker("Directory", selection: $directory) {
                            ForEach(dashboard.recentDirectories, id: \.self) { path in
                                Text((path as NSString).lastPathComponent).tag(path)
                            }
                        }
                        if !directory.isEmpty {
                            Text(directory).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Task") {
                    if dashboard.dispatchAgents.count > 1 {
                        Picker("Agent", selection: $agent) {
                            ForEach(dashboard.dispatchAgents, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                    }
                    TextField("What should \(agent.displayName) do?", text: $prompt, axis: .vertical).lineLimit(3...8)
                    TextField("Name (optional)", text: $name)
                }
                if agent == .cursor {
                    cursorSection
                }
                Section {
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Starting…" : "Start") { start() }
                        .disabled(busy || directory.isEmpty
                                  || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if directory.isEmpty { directory = dashboard.recentDirectories.first ?? "" }
                if !dashboard.dispatchAgents.contains(agent), let first = dashboard.dispatchAgents.first { agent = first }
            }
        }
    }

    /// Cursor's three launch choices. The model list comes from the Mac's
    /// `cursor-agent --list-models`; when the Mac has none, the row stays
    /// out and the CLI's default model is used.
    private var cursorSection: some View {
        Section {
            if !dashboard.cursorModels.isEmpty {
                Picker("Model", selection: $cursorModel) {
                    Text("Default").tag("")
                    ForEach(dashboard.cursorModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }
            Picker("Mode", selection: $cursorMode) {
                ForEach(CursorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Toggle("Run in a new worktree", isOn: $cursorWorktree)
        } header: {
            Text("Cursor")
        } footer: {
            Text("A new worktree is created on your Mac under ~/.cursor/worktrees/<repo>/<name>; Plan and Ask are read-only.")
        }
    }

    private var explanation: String {
        switch agent {
        case .codex:
            return "Runs as a new Codex thread on your Mac through the app-server daemon, with your usual model, approval and sandbox settings. It appears in Codex Desktop and in Working here."
        case .cursor:
            return "Hosted by vibebuddy on your Mac over the Cursor CLI. It appears in Working here and can be stopped, continued and answered from this phone; it ends if vibebuddy quits."
        default:
            return "Runs as a Claude Code background session on your Mac (claude --bg) with your usual settings. It appears in Working here; Jump opens a terminal attached to it."
        }
    }

    private func start() {
        busy = true
        let cursor = agent == .cursor
        let request = DispatchRequest(agent: agent, cwd: directory,
                                      prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                      name: name.isEmpty ? nil : name,
                                      model: cursor && !cursorModel.isEmpty ? cursorModel : nil,
                                      mode: cursor ? cursorMode.wireValue : nil,
                                      worktree: cursor && cursorWorktree ? true : nil)
        Task {
            let result = await dashboard.dispatch(request)
            busy = false
            if result?.hasPrefix("started") == true { dismiss() }
        }
    }
}
