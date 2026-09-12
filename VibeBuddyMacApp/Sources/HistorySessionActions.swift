import AppKit
import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

@MainActor
struct HistorySessionActions: View {
    let session: SessionHistorySession
    @ObservedObject var model: MenuBarModel
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let live = Self.liveSession(for: session, in: model.sessions) {
                Button("Jump to current session") {
                    guard let current = Self.liveSession(for: session, in: model.sessions) else {
                        feedback = "The live session is no longer available."
                        return
                    }
                    model.jump(current)
                }
                if live.agent == .codex && live.status != .needsResponse && SessionActionSupport.resolve(for: live).isAvailable {
                    InstructionComposer(placeholder: live.status == .done ? "Start a new turn…" : "Add to the current turn…") { text in
                        guard let current = Self.liveSession(for: session, in: model.sessions),
                              current.status == live.status, current.statusSince == live.statusSince,
                              current.status != .needsResponse,
                              SessionActionSupport.resolve(for: current).isAvailable else {
                            feedback = "The task changed. Review its current state before sending."
                            return
                        }
                        model.answer(current.id, answers: [:], text: text)
                    }
                    .id(live.id + String(live.statusSince.timeIntervalSince1970))
                }
                if let outcome = model.jumpFeedback[live.id] { Text(outcome.macMessage(for: live)) }
                if let answer = model.answerFeedback[live.id] { Text(answer) }
            } else {
                if Self.resumeCommand(for: session) != nil {
                    Button("Copy resume command") {
                        feedback = Self.copyResumeCommand(for: session)
                            ? "Resume command copied. Run it in your terminal to continue."
                            : "The resume command is no longer available."
                    }
                }
                Text(Self.unavailableReason(for: session)).foregroundStyle(.secondary)
            }
            if let feedback { Text(feedback).foregroundStyle(.secondary) }
        }
        .font(.caption)
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
        if !history.isAvailable { return "Source unavailable. Cached history does not establish a recoverable session." }
        if history.sourceArchived == true { return "Archived in Codex. Unarchive the original task in Codex before continuing." }
        if history.agent == .codex && history.source != "cli" {
            return "This archive does not establish a Codex CLI or Desktop target. Open the original task in Codex to continue."
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: history.projectPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
            return "The original project directory is unavailable."
        }
        if resumeCommand(for: history) == nil { return "This record has no valid session identity for resuming." }
        return "Copy the resume command and run it in your terminal. Copying does not start or continue a task."
    }
}
