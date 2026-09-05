import SwiftUI
import VibeBuddyKit

/// Start a new task on the Mac from the phone: a directory the Mac has seen a
/// session run in, the prompt, an optional name. Codex only for now.
struct NewTaskSheet: View {
    @ObservedObject var dashboard: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var directory = ""
    @State private var prompt = ""
    @State private var name = ""
    @State private var busy = false

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
                    TextField("What should Codex do?", text: $prompt, axis: .vertical).lineLimit(3...8)
                    TextField("Name (optional)", text: $name)
                }
                Section {
                    Text("Runs as a new Codex thread on your Mac through the app-server daemon, with your usual model, approval and sandbox settings. It appears in Codex Desktop and in Working here.")
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
            .onAppear { if directory.isEmpty { directory = dashboard.recentDirectories.first ?? "" } }
        }
    }

    private func start() {
        busy = true
        let request = DispatchRequest(agent: .codex, cwd: directory,
                                      prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                      name: name.isEmpty ? nil : name)
        Task {
            let result = await dashboard.dispatch(request)
            busy = false
            if result?.hasPrefix("started") == true { dismiss() }
        }
    }
}
