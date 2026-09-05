import SwiftUI
import VibeBuddyKit

/// Start a new agent task from the Mac: pick one of the directories a session
/// has already run in, write the prompt, optionally name it. Claude Code
/// starts as a `claude --bg` background session, Codex as a thread on the
/// app-server daemon; only agents the Mac can start right now are offered.
struct NewTaskSheet: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind = .claudeCode
    @State private var directory = ""
    @State private var prompt = ""
    @State private var name = ""
    @State private var feedback: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New task").font(.title3.bold())
            Picker("Agent", selection: $agent) {
                ForEach(model.dispatchAgents, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            Picker("Directory", selection: $directory) {
                ForEach(model.recentDirectories, id: \.self) { path in
                    Text(path).tag(path)
                }
            }
            TextField("Task name (optional)", text: $name).textFieldStyle(.roundedBorder)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if let feedback {
                Label(feedback, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Starting…" : "Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !model.dispatchAgents.contains(agent) || directory.isEmpty
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if directory.isEmpty { directory = model.recentDirectories.first ?? "" }
            if !model.dispatchAgents.contains(agent), let first = model.dispatchAgents.first { agent = first }
        }
    }

    private func start() {
        busy = true
        let request = DispatchRequest(agent: agent, cwd: directory,
                                      prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                      name: name.isEmpty ? nil : name)
        Task {
            let outcome = await model.dispatch(request)
            busy = false
            switch outcome {
            case .started: dismiss()
            case .rejected(let why), .unsupported(let why), .unavailable(let why): feedback = why
            }
        }
    }
}
