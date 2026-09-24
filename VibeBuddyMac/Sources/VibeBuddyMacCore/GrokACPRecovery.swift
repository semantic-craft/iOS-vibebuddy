import Foundation

/// What a Grok Build session vibebuddy hosted over ACP keeps so a host started
/// later — after a daemon or app restart — can `session/load` it and go on
/// (ADR-0030, amendment 1). Grok stores the conversation itself under
/// `<grok home>/sessions`; this is only where and with which model to reopen it.
struct GrokACPRecovery: ACPRecoveryRecord {
    let sessionID: String
    let cwd: String
    let model: String?
    let createdAt: Date
    var updatedAt: Date?
    let origin: String

    static let expectedOrigin = "vibebuddy-grok-acp"

    init(sessionID: String, cwd: String, model: String?, createdAt: Date, updatedAt: Date? = nil) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        origin = Self.expectedOrigin
    }

    static var directory: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/vibebuddy/grok-acp")
    }
}

/// Grok Build in a terminal window: the way back into a hosted session that
/// can no longer be loaded over ACP.
public enum GrokCLI {
    /// Grok's session ids are UUIDs; anything else is refused before it
    /// reaches a shell.
    static func isSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// `cd <cwd> && grok --resume=<id>`, the command a terminal runs. The
    /// attached `--resume=` form: the flag's value is optional, so a detached
    /// id could be read as the prompt.
    static func resumeCommand(sessionID: String, cwd: String?, executable: URL) -> String? {
        guard isSessionID(sessionID) else { return nil }
        return CursorCLI.command([CursorCLI.shellQuoted(executable.path), "--resume=\(sessionID)"], cwd: cwd)
    }

    /// Reopen a Grok session interactively in the preferred terminal.
    public static func resume(sessionID: String, cwd: String?,
                              executable: URL? = GrokUsageProvider.resolveGrokExecutable(),
                              preferring termProgram: String? = nil) async -> Bool {
        guard let executable, let command = resumeCommand(sessionID: sessionID, cwd: cwd, executable: executable)
        else { return false }
        return await TerminalLauncher.open(command: command, preferring: termProgram)
    }
}
