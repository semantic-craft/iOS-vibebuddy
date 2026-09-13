import AppKit
import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// The action row under a conversation's title, in the dashboard's own
/// chrome: one filled key for the thing you most likely came to do (jump to
/// the live session, or copy the resume command), the star as a ghost
/// pill, and the library housekeeping — pin, archive, export, show source —
/// behind a `···` pill. A Codex thread's composer and any feedback sit on
/// the line below.
@MainActor
struct HistorySessionActions: View {
    let session: SessionHistorySession
    @ObservedObject var model: MenuBarModel
    @ObservedObject var history: HistoryLibraryModel
    let export: () -> Void
    @State private var feedback: String?

    private var live: AgentSession? { Self.liveSession(for: session, in: model.sessions) }
    private var canExport: Bool {
        !history.reading && history.transcript?.id == session.id && history.readingError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if live != nil {
                    Button("Jump to current session") {
                        guard let current = live else {
                            feedback = String(localized: "The live session is no longer available.")
                            return
                        }
                        model.jump(current)
                    }
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent), size: .small))
                } else if Self.resumeCommand(for: session) != nil {
                    Button("Copy resume command") {
                        feedback = Self.copyResumeCommand(for: session)
                            ? String(localized: "Resume command copied. Run it in your terminal to continue.")
                            : String(localized: "The resume command is no longer available.")
                    }
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent), size: .small))
                }
                Button { Task { await history.toggleFavorite(session) } } label: {
                    Image(systemName: session.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(session.isFavorite ? MacTheme.status(.requiresInput) : MacTheme.ink2)
                        .frame(width: 12)
                }
                .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
                .help(session.isFavorite ? "Unfavorite" : "Favorite")
                .accessibilityLabel(session.isFavorite ? "Unfavorite" : "Favorite")
                MenuPill(title: "···") {
                    Button(session.isPinned == true ? "Unpin" : "Pin") { Task { await history.togglePinned(session) } }
                    Button(session.archivedLocally == true ? "Unarchive in library" : "Archive in library") {
                        Task { await history.toggleArchive(session) }
                    }
                    Divider()
                    Button("Export Markdown…", action: export).disabled(!canExport)
                    Button("Show source") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.sourcePath)])
                    }
                    .disabled(!session.isAvailable)
                }
                .help("Pin, archive in this library, export or show the source file. Archiving organizes this library only; the original agent and current tasks are unchanged.")
                .accessibilityLabel("More actions")
            }
            if let live {
                if live.agent == .codex && live.status != .needsResponse && SessionActionSupport.resolve(for: live).isAvailable {
                    InstructionComposer(placeholder: live.status == .done ? "Start a new turn…" : "Add to the current turn…") { text in
                        guard let current = Self.liveSession(for: session, in: model.sessions),
                              current.status == live.status, current.statusSince == live.statusSince,
                              current.status != .needsResponse,
                              SessionActionSupport.resolve(for: current).isAvailable else {
                            feedback = String(localized: "The task changed. Review its current state before sending.")
                            return
                        }
                        model.answer(current.id, answers: [:], text: text)
                    }
                    .id(live.id + String(live.statusSince.timeIntervalSince1970))
                }
                if let outcome = model.jumpFeedback[live.id] { Text(outcome.macMessage(for: live)) }
                if let answer = model.answerFeedback[live.id] { Text(answer) }
            } else {
                Text(Self.unavailableReason(for: session)).foregroundStyle(MacTheme.ink2)
            }
            if let feedback { Text(feedback).foregroundStyle(MacTheme.ink2) }
        }
        .font(MacTheme.font(10))
        .onChange(of: session.id) { _, _ in feedback = nil }
    }

    static func liveSession(for history: SessionHistorySession, in sessions: [AgentSession]) -> AgentSession? {
        HistoryResumePolicy.liveSession(for: history, in: sessions)
    }

    static func resumeCommand(for history: SessionHistorySession) -> String? {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: history.projectPath, isDirectory: &isDirectory)
        return HistoryResumePolicy.command(for: history, directoryExists: exists && isDirectory.boolValue)
    }

    @discardableResult
    static func copyResumeCommand(for history: SessionHistorySession) -> Bool {
        guard let command = resumeCommand(for: history) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(command, forType: .string)
    }

    static func unavailableReason(for history: SessionHistorySession) -> String {
        if !history.isAvailable { return String(localized: "Source unavailable. Cached history does not establish a recoverable session.") }
        if history.sourceArchived == true { return String(localized: "Archived in Codex. Unarchive the original task in Codex before continuing.") }
        if history.agent == .codex && history.source != "cli" {
            return String(localized: "This archive does not establish a Codex CLI or Desktop target. Open the original task in Codex to continue.")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: history.projectPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
            return String(localized: "The original project directory is unavailable.")
        }
        if resumeCommand(for: history) == nil { return String(localized: "This record has no valid session identity for resuming.") }
        return String(localized: "Copy the resume command and run it in your terminal. Copying does not start or continue a task.")
    }
}
