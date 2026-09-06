import SwiftUI
import VibeBuddyKit

/// Start a new task on the Mac from the phone: a directory the Mac has seen a
/// session run in, the agent, the prompt, an optional name. Claude Code runs
/// as a `claude --bg` background session, Codex as a daemon thread.
struct NewTaskSheet: View {
    @ObservedObject var dashboard: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind = .claudeCode
    @State private var directory = ""
    @State private var prompt: String
    @State private var name = ""
    @State private var busy = false

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
                Section {
                    Text(agent == .codex
                         ? "Runs as a new Codex thread on your Mac through the app-server daemon, with your usual model, approval and sandbox settings. It appears in Codex Desktop and in Working here."
                         : "Runs as a Claude Code background session on your Mac (claude --bg) with your usual settings. It appears in Working here; Jump opens a terminal attached to it.")
                        .font(.caption).foregroundStyle(.secondary)
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

    private func start() {
        busy = true
        let request = DispatchRequest(agent: agent, cwd: directory,
                                      prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                      name: name.isEmpty ? nil : name)
        Task {
            let result = await dashboard.dispatch(request)
            busy = false
            if result?.hasPrefix("started") == true { dismiss() }
        }
    }
}
