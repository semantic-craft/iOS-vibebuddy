import Foundation
import VibeBuddyKit

/// Starts a Claude Code background session for a dispatch:
/// `claude --bg [--name <name>] -- <prompt>` in the requested directory. The
/// CLI prints `backgrounded · <job id> · <name>` and writes
/// `~/.claude/jobs/<job id>/state.json` with the full session id, which is the
/// id the hooks will report — so the phone can match the row that appears.
/// Whether the installed CLI supports `--bg` is probed once and cached.
public actor ClaudeBackgroundLauncher {
    private let executable: URL?
    private let jobsDirectory: URL
    private let launchTimeout: TimeInterval
    private var supported: Bool?

    public init(executable: URL? = ClaudeCLIUsageProvider.resolveClaudeExecutable(),
                jobsDirectory: URL = ClaudeBackgroundSessions.jobsDirectory(),
                launchTimeout: TimeInterval = 30) {
        self.executable = executable
        self.jobsDirectory = jobsDirectory
        self.launchTimeout = launchTimeout
    }

    /// True when a `claude` binary is installed and its help lists `--bg`.
    public func isSupported() async -> Bool {
        if let supported { return supported }
        guard let executable else { supported = false; return false }
        let result = await Self.run(executable, ["--help"], cwd: nil, timeout: 15)
        let ok = result.status == 0 && result.stdout.contains("--bg")
        supported = ok
        return ok
    }

    public func dispatch(_ request: DispatchRequest) async -> DispatchOutcome {
        guard request.agent == .claudeCode else {
            return .unsupported("This launcher only starts Claude Code sessions")
        }
        guard let executable, await isSupported() else {
            return .unavailable("Claude Code CLI with background sessions (--bg) not found on this Mac")
        }
        var arguments = ["--bg"]
        if let name = request.name { arguments += ["--name", name] }
        arguments += ["--", request.prompt]
        let result = await Self.run(executable, arguments, cwd: URL(fileURLWithPath: request.cwd), timeout: launchTimeout)
        guard result.status == 0, let job = Self.jobID(in: result.stdout) else {
            let why = result.stderr.split(separator: "\n").last.map(String.init)
                ?? result.stdout.split(separator: "\n").last.map(String.init)
                ?? "claude --bg exited with status \(result.status)"
            return .unavailable(why)
        }
        // The state file normally exists before the CLI returns; give it a moment.
        for _ in 0..<10 {
            if let session = ClaudeBackgroundSessions.load(jobsDirectory: jobsDirectory).first(where: { $0.id == job }) {
                return .started(sessionID: session.sessionID)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return .started(sessionID: job)
    }

    static func jobID(in output: String) -> String? {
        for line in output.split(separator: "\n") where line.contains("backgrounded") {
            let parts = line.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2, ClaudeBackgroundSessions.isJobID(parts[1]) { return parts[1] }
        }
        return nil
    }

    struct Result: Sendable { let status: Int32; let stdout: String; let stderr: String }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?
        init(_ c: CheckedContinuation<Result, Never>) { continuation = c }
        func finish(_ r: Result) { lock.lock(); defer { lock.unlock() }; continuation?.resume(returning: r); continuation = nil }
    }

    private static func run(_ executable: URL, _ arguments: [String], cwd: URL?, timeout: TimeInterval) async -> Result {
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
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { p in
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                once.finish(Result(status: p.terminationStatus, stdout: o, stderr: e))
            }
            do { try process.run() } catch {
                once.finish(Result(status: -1, stdout: "", stderr: error.localizedDescription)); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    once.finish(Result(status: -1, stdout: "", stderr: "claude --bg did not return within \(Int(timeout))s"))
                }
            }
        }
    }
}
