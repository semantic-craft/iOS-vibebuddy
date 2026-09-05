import Foundation
import VibeBuddyKit

/// Opens a new terminal window running one command — the way back into a
/// Claude background session, which has no window of its own. iTerm2 when the
/// user's sessions run there, Terminal.app otherwise: both script a new
/// window with a command in one AppleScript call and need no extra install.
public enum TerminalLauncher {
    /// `claude attach <id>` in the preferred terminal. The id is validated as a
    /// job id before it is interpolated into a script.
    public static func attach(claudeJobID id: String, preferring termProgram: String?) async -> JumpOutcome {
        guard ClaudeBackgroundSessions.isJobID(id) else { return .unsupported }
        return await open(command: "claude attach \(id)", preferring: termProgram) ? .attached : .unsupported
    }

    static func open(command: String, preferring termProgram: String?) async -> Bool {
        let script: String
        switch termProgram?.lowercased() {
        case "iterm.app":
            script = """
            tell application id "com.googlecode.iterm2"
            \tcreate window with default profile command "\(escaped(command))"
            \tactivate
            end tell
            """
        default:
            script = """
            tell application id "com.apple.Terminal"
            \tdo script "\(escaped(command))"
            \tactivate
            end tell
            """
        }
        return await run([TerminalCommand.osascriptPath, "-e", script], timeout: 10)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Resumes a continuation exactly once, from whichever of the termination
    /// handler or the timeout fires first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ ok: Bool) {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(returning: ok)
            continuation = nil
        }
    }

    private static func run(_ argv: [String], timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { once.finish($0.terminationStatus == 0) }
            do { try process.run() } catch { once.finish(false); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate(); once.finish(false) }
            }
        }
    }
}
