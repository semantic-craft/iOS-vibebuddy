import Foundation
import VibeBuddyKit

/// The `cursor-agent` binary: where it is, whether it is signed in, and the two
/// things vibebuddy asks of it — resume a conversation, or start a new one.
///
/// Both run in a terminal window rather than headless. A dispatched or resumed
/// Cursor turn has output worth watching and prompts worth answering, and a
/// detached `--print` run would put both somewhere nobody can see. This mirrors
/// how a Claude background session is re-entered (`TerminalLauncher.attach`).
public enum CursorCLI {

    /// The conversation-id shape Cursor uses for composers and CLI chats: a
    /// UUID, or the `bc-`-prefixed id a cloud agent carries. Validated before it
    /// is ever interpolated into a shell command.
    public static func isConversationID(_ id: String) -> Bool {
        let bare = id.hasPrefix("bc-") ? String(id.dropFirst(3)) : id
        guard bare.count == 36 else { return false }
        return UUID(uuidString: bare) != nil
    }

    public static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let fixed = [
            home.appendingPathComponent(".local/bin/cursor-agent").path,
            "/opt/homebrew/bin/cursor-agent",
            "/usr/local/bin/cursor-agent",
            "/usr/bin/cursor-agent",
        ]
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/cursor-agent" }
        return (fixed + fromPath)
            .first(where: fileManager.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    /// Cursor's CLI keeps its own credentials, separate from the app's. A signed
    /// out CLI exists and runs but refuses every prompt, so "installed" is not
    /// enough to offer a dispatch — this is what decides it.
    ///
    /// `~/.cursor/agent-cli-state.json` is written once the CLI has run; the
    /// credential itself lives in the login keychain and is never read here.
    public static func isSignedIn(
        executable: URL? = resolveExecutable(),
        timeout: TimeInterval = 10
    ) async -> Bool {
        guard let executable else { return false }
        let result = await run(executable, ["status"], cwd: nil, timeout: timeout)
        guard result.status == 0 else { return false }
        let text = (result.stdout + result.stderr).lowercased()
        guard !text.contains("authentication required"), !text.contains("not logged in"),
              !text.contains("please run") else { return false }
        return text.contains("logged in") || text.contains("@") || text.contains("email")
    }

    /// Continue an existing conversation in a terminal: `cursor-agent --resume
    /// <id> -- <text>`. The id is validated first; the text is passed as the
    /// prompt argument.
    public static func resume(
        conversationID: String, text: String,
        executable: URL? = resolveExecutable(),
        cwd: String?,
        preferring termProgram: String? = nil
    ) async -> Bool {
        guard let executable, isConversationID(conversationID) else { return false }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }
        // `--resume=<id>` rather than `--resume <id>`: the flag's value is
        // optional, so the attached form is the one that cannot be read as the
        // prompt instead of the chat id.
        let parts = [shellQuoted(executable.path), "--resume=\(conversationID)",
                     "--", shellQuoted(prompt)]
        return await TerminalLauncher.open(command: command(parts, cwd: cwd),
                                           preferring: termProgram)
    }

    /// Start a new Cursor task in a terminal: `cursor-agent -- <prompt>` in the
    /// requested directory.
    public static func start(
        prompt: String,
        executable: URL? = resolveExecutable(),
        cwd: String,
        preferring termProgram: String? = nil
    ) async -> Bool {
        guard let executable else { return false }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let parts = [shellQuoted(executable.path), "--", shellQuoted(text)]
        return await TerminalLauncher.open(command: command(parts, cwd: cwd),
                                           preferring: termProgram)
    }

    /// `cd <dir> && <argv>`. The directory is quoted like every other argument;
    /// a missing one just runs where the terminal opens.
    static func command(_ parts: [String], cwd: String?) -> String {
        let argv = parts.joined(separator: " ")
        guard let cwd, !cwd.isEmpty else { return argv }
        return "cd \(shellQuoted(cwd)) && \(argv)"
    }

    /// Single-quote for `/bin/sh`, the only quoting that is safe for arbitrary
    /// text: an embedded quote closes, escapes and reopens.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct Result: Sendable { let status: Int32; let stdout: String; let stderr: String }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?
        init(_ c: CheckedContinuation<Result, Never>) { continuation = c }
        func finish(_ r: Result) {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(returning: r)
            continuation = nil
        }
    }

    private static func run(_ executable: URL, _ arguments: [String], cwd: URL?,
                            timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            var environment = ProcessInfo.processInfo.environment
            environment["LANG"] = "en_US.UTF-8"
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { finished in
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                once.finish(Result(status: finished.terminationStatus, stdout: stdout, stderr: stderr))
            }
            do { try process.run() } catch {
                once.finish(Result(status: -1, stdout: "", stderr: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// Jump into a Cursor conversation.
///
/// Cursor publishes exactly three deeplinks — `prompt`, `command`, `rule` — and
/// none of them opens a chat by id (cursor.com/docs/reference/deeplinks, checked
/// 2026-09-12). So the closest honest jump is: bring Cursor forward, and when
/// the session records a project, open that folder so the right window is the
/// one in front. The chat itself is where the person left it in Cursor's sidebar.
public enum CursorJumper {
    public static func jump(project: String?, bundleID: String = "com.todesktop.230313mzl4w4u92") async -> JumpOutcome {
        let directory = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var isDirectory: ObjCBool = false
        if !directory.isEmpty,
           FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
           isDirectory.boolValue {
            if await open(["-b", bundleID, directory]) { return .focused }
        }
        return await open(["-b", bundleID]) ? .focused : .unsupported
    }

    /// Resumes a continuation exactly once, whichever of the termination handler
    /// and the timeout fires first.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ ok: Bool) {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(returning: ok)
            continuation = nil
        }
    }

    private static func open(_ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let once = Gate(continuation)
            process.terminationHandler = { once.finish($0.terminationStatus == 0) }
            do { try process.run() } catch { once.finish(false); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if process.isRunning { process.terminate(); once.finish(false) }
            }
        }
    }
}
