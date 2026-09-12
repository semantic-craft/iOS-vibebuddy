import SwiftUI
import AppKit
import VibeBuddyKit

/// Start a new agent task from the Mac: pick the agent, the directory, write
/// the prompt, optionally name it. Claude Code starts as a `claude --bg`
/// background session, Codex as a thread on the app-server daemon, Cursor
/// through its CLI. The sheet always opens; when no agent can start from this
/// Mac it says which one needs what, instead of a greyed-out button.
struct NewTaskSheet: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind = .claudeCode
    @State private var directory = ""
    /// Folders picked with the open panel, on top of the ones sessions ran in.
    @State private var chosenDirectories: [String] = []
    @State private var prompt = ""
    @State private var name = ""
    @State private var feedback: String?
    @State private var busy = false

    private var directories: [String] {
        var seen = Set<String>()
        return (chosenDirectories + model.recentDirectories).filter { seen.insert($0).inserted }
    }
    private var canStart: Bool {
        !busy && model.dispatchAgents.contains(agent) && !directory.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New task").font(MacTheme.font(15, .semibold)).foregroundStyle(MacTheme.ink)
                Spacer()
                MenuCircleButton(systemName: "xmark", size: 22, tint: MacTheme.ink2) { dismiss() }
                    .accessibilityLabel("Close")
            }

            if model.dispatchAgents.isEmpty {
                unavailable
            } else {
                HStack(spacing: 6) {
                    ForEach(model.dispatchAgents, id: \.self) { kind in
                        FilterChip(title: LocalizedStringKey(kind.displayName), selected: agent == kind) { agent = kind }
                    }
                    Spacer(minLength: 8)
                    MenuPill(title: directory.isEmpty ? String(localized: "Choose folder…")
                                                      : URL(fileURLWithPath: directory).lastPathComponent) {
                        ForEach(directories, id: \.self) { path in
                            Button(path) { directory = path }
                        }
                        if !directories.isEmpty { Divider() }
                        Button("Choose folder…") { chooseFolder() }
                    }
                    .help(directory.isEmpty ? String(localized: "Directory") : directory)
                }
                .accessibilityLabel("Agent")
            }

            // Without an agent there is nothing to type for; `.disabled` alone
            // still lets the editor take focus and swallow Escape.
            if !model.dispatchAgents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Task name (optional)", text: $name)
                        .textFieldStyle(.plain).font(MacTheme.font(12, .medium)).foregroundStyle(MacTheme.ink)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    Divider()
                    TextEditor(text: $prompt)
                        .font(MacTheme.font(13)).foregroundStyle(MacTheme.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text("What should the agent do?").font(MacTheme.font(13)).foregroundStyle(MacTheme.ink3)
                                    .padding(.horizontal, 13).padding(.vertical, 6).allowsHitTesting(false)
                            }
                        }
                }
                .companionCard()
            }

            if let feedback {
                Label(feedback, systemImage: "info.circle").font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if model.dispatchAgents.isEmpty {
                    Button("Open Settings") {
                        NotificationCenter.default.post(name: .openAppSettings, object: nil)
                        dismiss()
                    }
                    .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "Starting…" : "Start") { start() }
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent), size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.5)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(MacTheme.bg)
        .onExitCommand { dismiss() }
        .onAppear {
            if directory.isEmpty { directory = model.recentDirectories.first ?? "" }
            if !model.dispatchAgents.contains(agent), let first = model.dispatchAgents.first { agent = first }
        }
    }

    /// What each agent needs before the Mac can start it; the same three
    /// checks `MenuBarModel` runs to fill `dispatchAgents`.
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No agent can start from this Mac yet.").font(MacTheme.font(12, .semibold)).foregroundStyle(MacTheme.ink)
            requirement("Claude Code", "needs a `claude` that supports background sessions.")
            requirement("Codex", "needs the app-server connection from Settings › Agent CLIs.")
            requirement("Cursor", "needs the Cursor CLI, or ACP, on this Mac.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard(MacTheme.bg2)
    }

    private func requirement(_ agent: String, _ what: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(agent).font(MacTheme.font(11, .medium)).foregroundStyle(MacTheme.ink)
            Text(what).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let path = url.path
            if !chosenDirectories.contains(path) { chosenDirectories.insert(path, at: 0) }
            directory = path
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func start() {
        busy = true
        let request = DispatchRequest(agent: agent, cwd: directory,
                                      prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                      name: name.isEmpty ? nil : name)
        Task {
            let outcome = await model.dispatch(request, userChoseDirectory: chosenDirectories.contains(directory))
            busy = false
            switch outcome {
            case .started: dismiss()
            case .rejected(let why), .unsupported(let why), .unavailable(let why): feedback = why
            }
        }
    }
}
