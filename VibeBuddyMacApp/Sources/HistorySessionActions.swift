import AppKit
import Foundation
import VibeBuddyKit
import VibeBuddyMacCore

/// What a history record can still do on this Mac. The reader's head asks
/// these before it draws a jump or a copy key, so every control it shows is
/// backed by an actual capability (ADR-0024). Copying never runs anything.
enum HistorySessionSupport {
    static func liveSession(for history: SessionHistorySession, in sessions: [AgentSession]) -> AgentSession? {
        HistoryResumePolicy.liveSession(for: history, in: sessions)
    }

    static func resumeCommand(for history: SessionHistorySession) -> String? {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: history.projectPath, isDirectory: &isDirectory)
        return HistoryResumePolicy.command(for: history, directoryExists: exists && isDirectory.boolValue,
                                           cursorCLIAvailable: CursorCLI.resolveExecutable() != nil)
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
        if history.agent == .cursor && CursorCLI.resolveExecutable() == nil {
            return String(localized: "Install the Cursor CLI to copy a resume command for this local conversation.")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: history.projectPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
            return String(localized: "The original project directory is unavailable.")
        }
        if resumeCommand(for: history) == nil { return String(localized: "This record has no valid session identity for resuming.") }
        return String(localized: "Copy the resume command and run it in your terminal. Copying does not start or continue a task.")
    }
}
