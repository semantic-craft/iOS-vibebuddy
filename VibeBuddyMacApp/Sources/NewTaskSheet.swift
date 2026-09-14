import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// Start a new agent task from the Mac: pick the agent, the directory, write
/// the prompt, optionally name it. Claude Code starts as a `claude --bg`
/// background session, Codex as a thread on the app-server daemon, Cursor
/// through its CLI. The sheet always opens; when no agent can start from this
/// Mac it says which one needs what, instead of a greyed-out button.
/// What Continue with… puts into the sheet before the person reviews it
/// (ADR-0023 §4): the receiver's first prompt points at the handoff's path.
struct NewTaskPrefill: Equatable {
    struct Continuation: Equatable {
        var sessionID: String
        var sourceKey: String
        var handoffPath: String?
    }
    var agent: AgentKind
    var directory: String
    var name: String
    var prompt: String
    var continuing: Continuation?
}

struct NewTaskSheet: View {
    @ObservedObject var model: MenuBarModel
    var prefill: NewTaskPrefill?
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind = .claudeCode
    @State private var directory = ""
    /// Folders picked with the open panel, on top of the ones sessions ran in.
    @State private var chosenDirectories: [String] = []
    @State private var prompt = ""
    @State private var name = ""
    @State private var feedback: String?
    @State private var busy = false
    /// Cursor only: `-w`, a fresh worktree the CLI creates.
    @State private var freshWorktree = false

    private var title: LocalizedStringKey { prefill?.continuing == nil ? "New task" : "Continue with…" }
    /// Other sessions busy in the chosen directory: a hint, never a lock.
    private var busyElsewhere: [AgentSession] {
        directory.isEmpty ? [] : ContinueWith.busySessions(in: directory, among: model.sessions, excluding: prefill?.continuing?.sessionID)
    }

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
                Text(title).font(MacTheme.font(15, .semibold)).foregroundStyle(MacTheme.ink)
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
            // still lets the editor take focus and swallow Escape. A Continue
            // with… prefill is still shown, so what would be sent can be read
            // and copied even when nothing can start from this Mac.
            if !model.dispatchAgents.isEmpty || prefill?.continuing != nil {
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

            if let continuing = prefill?.continuing {
                Label(continuing.handoffPath.map { "Starts from the handoff at \(URL(fileURLWithPath: $0).lastPathComponent); the prompt points at its path." }
                        ?? "No handoff document names this session; the prompt points the agent at the history tools instead.",
                      systemImage: "arrow.turn.down.right")
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(continuing.handoffPath ?? continuing.sourceKey)
            }
            if !busyElsewhere.isEmpty {
                Label("\(busyElsewhere.count) other session(s) are working in this folder right now. Pick another folder if they should not share it.",
                      systemImage: "person.2")
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("busy-checkout-notice")
            }
            if agent == .cursor, model.dispatchAgents.contains(.cursor) {
                Toggle("Start in a fresh worktree", isOn: $freshWorktree)
                    .toggleStyle(.checkbox).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
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
        .onChange(of: directory) { _, selected in
            prompt = ContinueWith.promptForDispatch(prompt, handoffPath: prefill?.continuing?.handoffPath, checkout: selected)
        }
        .onAppear {
            if let prefill {
                agent = prefill.agent
                directory = prefill.directory
                name = prefill.name
                prompt = prefill.prompt
            }
            // A plain New task starts in the newest directory; a Continue with…
            // whose checkout the Mac never observed stays empty for the person to pick.
            if directory.isEmpty, prefill?.continuing == nil { directory = model.recentDirectories.first ?? "" }
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
                                      prompt: ContinueWith.promptForDispatch(prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                             handoffPath: prefill?.continuing?.handoffPath, checkout: directory),
                                      name: name.isEmpty ? nil : name,
                                      worktree: agent == .cursor && freshWorktree ? true : nil,
                                      continuation: prefill?.continuing.map { DispatchContinuation(sourceKey: $0.sourceKey, handoffPath: $0.handoffPath) })
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
