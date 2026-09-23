import Foundation
import VibeBuddyKit

/// A Claude Code background session (`claude --bg`, agent view, Dispatch), as
/// `claude agents --json --all` reports it — "the supported way to read
/// session state from outside Claude Code" (code.claude.com/docs/en/agent-view).
/// Read-only: vibebuddy never starts the supervisor and never creates or moves
/// a session from these entries — they only tell a jump where
/// `claude attach <id>` lands and lend a name or a "needs" line to a row the
/// hooks opened. Hooks stay the authority for state.
public struct ClaudeBackgroundSession: Sendable, Equatable {
    /// The short job id `claude attach` takes (the directory name).
    public let id: String
    public let sessionID: String
    public let name: String?
    public let state: String?
    /// What the session is waiting on (`waitingFor`), in the CLI's own words.
    public let needs: String?

    public init(id: String, sessionID: String, name: String? = nil, state: String? = nil, needs: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.name = name
        self.state = state
        self.needs = needs
    }
}

public enum ClaudeBackgroundSessions {
    public static func jobsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/jobs", isDirectory: true)
    }

    /// Background sessions from the shared cached source (see
    /// `ClaudeAgentsSource`). Cheap to call from a poll loop.
    public static func load() -> [ClaudeBackgroundSession] {
        ClaudeAgentsSource.shared.current()
    }

    /// The session for this id, refreshing once if the cache does not know it
    /// (a session started seconds ago, or a jump right after a change).
    public static func find(sessionID: String) -> ClaudeBackgroundSession? {
        if let hit = load().first(where: { $0.sessionID == sessionID }) { return hit }
        return ClaudeAgentsSource.shared.refreshNow().first { $0.sessionID == sessionID }
    }

    /// `claude agents --json` output: background entries only. Fields are
    /// decoded as they appear; `state` and `waitingFor` may be absent on some
    /// CLI versions. Interactive sessions are the hooks' business.
    public static func parseAgentsJSON(_ data: Data) -> [ClaudeBackgroundSession]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard (row["kind"] as? String) == "background",
                  let id = row["id"] as? String, isJobID(id),
                  let sessionID = nonEmpty(row["sessionId"] as? String) else { return nil }
            return ClaudeBackgroundSession(
                id: id, sessionID: sessionID,
                name: nonEmpty(row["name"] as? String),
                state: nonEmpty(row["state"] as? String),
                needs: nonEmpty(row["waitingFor"] as? String))
        }.sorted { $0.id < $1.id }
    }

    /// Fallback for CLIs without `claude agents --json`: the supervisor's
    /// `~/.claude/jobs/<id>/state.json` files, which the docs call "not a
    /// stable interface". Unreadable or malformed entries are skipped.
    public static func loadFromJobsDirectory(_ jobsDirectory: URL = jobsDirectory(),
                                             fileManager fm: FileManager = .default) -> [ClaudeBackgroundSession] {
        guard let names = try? fm.contentsOfDirectory(atPath: jobsDirectory.path) else { return [] }
        return names.sorted().compactMap { name in
            guard isJobID(name) else { return nil }
            let state = jobsDirectory.appendingPathComponent(name).appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: state),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else { return nil }
            return ClaudeBackgroundSession(
                id: name, sessionID: sessionID,
                name: nonEmpty(object["name"] as? String),
                state: nonEmpty(object["state"] as? String),
                needs: nonEmpty(object["needs"] as? String))
        }
    }

    /// Job ids are short hex; nothing else may reach a shell as `claude attach <id>`.
    public static func isJobID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32
            && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// The one place `claude agents --json --all` runs. The command costs about
/// half a second of CPU (1–2 s cold), and the Mac polls background sessions
/// every few seconds, so it runs only when something may have changed: a
/// cheap stat fingerprint of `~/.claude/jobs` differs from the last run, or
/// `maxAge` has passed. Jumps and launches ask for `refreshNow()`. When the
/// CLI is missing, fails or times out, the jobs files are read instead and a
/// warning is logged once.
public final class ClaudeAgentsSource: @unchecked Sendable {
    public static let shared = ClaudeAgentsSource()

    public typealias Runner = @Sendable () -> Data?
    public typealias Fingerprint = @Sendable () -> String

    private let lock = NSLock()
    private let run: Runner
    private let fingerprint: Fingerprint
    private let fallback: @Sendable () -> [ClaudeBackgroundSession]
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var cached: [ClaudeBackgroundSession] = []
    private var lastRun: Date?
    private var lastFingerprint: String?
    private var warnedFallback = false
    /// Commands actually run. Exposed for tests.
    public private(set) var runCount = 0

    public init(run: Runner? = nil,
                fingerprint: Fingerprint? = nil,
                fallback: (@Sendable () -> [ClaudeBackgroundSession])? = nil,
                maxAge: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.run = run ?? { ClaudeAgentsSource.runCLI() }
        self.fingerprint = fingerprint ?? { ClaudeAgentsSource.jobsFingerprint() }
        self.fallback = fallback ?? { ClaudeBackgroundSessions.loadFromJobsDirectory() }
        self.maxAge = maxAge
        self.now = now
    }

    /// The cached list, refreshed first when the jobs fingerprint changed or
    /// the cache is older than `maxAge`.
    public func current() -> [ClaudeBackgroundSession] {
        let print = fingerprint()
        lock.lock()
        let fresh = lastRun.map { now().timeIntervalSince($0) < maxAge } ?? false
        let stale = !fresh || print != lastFingerprint
        let value = cached
        lock.unlock()
        return stale ? refresh(fingerprint: print) : value
    }

    /// Run the command now, whatever the cache says.
    @discardableResult
    public func refreshNow() -> [ClaudeBackgroundSession] {
        refresh(fingerprint: fingerprint())
    }

    private func refresh(fingerprint print: String) -> [ClaudeBackgroundSession] {
        let parsed = run().flatMap(ClaudeBackgroundSessions.parseAgentsJSON)
        lock.lock(); defer { lock.unlock() }
        runCount += 1
        lastRun = now()
        lastFingerprint = print
        if let parsed {
            cached = parsed
        } else {
            if !warnedFallback {
                warnedFallback = true
                FileHandle.standardError.write(Data("vibebuddy: `claude agents --json` unavailable; reading ~/.claude/jobs (not a stable interface)\n".utf8))
            }
            cached = fallback()
        }
        return cached
    }

    /// Names plus modification times of `~/.claude/jobs` and each job's
    /// state file: a change hint only, never parsed for content.
    static func jobsFingerprint(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let jobs = ClaudeBackgroundSessions.jobsDirectory(home: home)
        func mtime(_ path: String) -> String {
            var info = stat()
            guard stat(path, &info) == 0 else { return "-" }
            return "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: jobs.path)) ?? []).sorted()
        return ([mtime(jobs.path)] + names.map { "\($0)@\(mtime(jobs.appendingPathComponent($0).appendingPathComponent("state.json").path))" })
            .joined(separator: "|")
    }

    /// `claude agents --json --all`, bounded; nil on any failure.
    static func runCLI(environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       timeout: TimeInterval = 15) -> Data? {
        guard let binary = ClaudeExecutable.resolve(environment: environment, home: home) else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["agents", "--json", "--all"]
        process.environment = ClaudeExecutable.runEnvironment(for: binary, environment: environment, home: home)
        process.currentDirectoryURL = home
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let collected = DataBox()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            collected.set(out.fileHandleForReading.readDataToEndOfFile())
            reader.leave()
        }
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        if reader.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? collected.get() : nil
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
