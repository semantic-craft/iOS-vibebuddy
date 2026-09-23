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

    /// The shared cached list, never blocking (see `ClaudeAgentsSource`).
    public static func load() -> [ClaudeBackgroundSession] {
        ClaudeAgentsSource.shared.current()
    }

    /// The shared list, waiting for a refresh first when it is stale.
    public static func loadFresh() async -> [ClaudeBackgroundSession] {
        await ClaudeAgentsSource.shared.currentFresh()
    }

    /// The session for this id, refreshing once if the cache does not know it
    /// (a session started seconds ago, or a jump right after a change).
    public static func find(sessionID: String) async -> ClaudeBackgroundSession? {
        if let hit = await loadFresh().first(where: { $0.sessionID == sessionID }) { return hit }
        return await ClaudeAgentsSource.shared.refreshNow().first { $0.sessionID == sessionID }
    }

    /// `claude agents --json` output: background entries only. Fields are
    /// decoded as they appear; `state` and `waitingFor` may be absent on some
    /// CLI versions. Interactive sessions are the hooks' business.
    /// `needs` is the CLI's `waitingFor`; Claude Code 2.1.280 omits it, so the
    /// job's own `needs` line (`jobNeeds`) fills in for that id only.
    public static func parseAgentsJSON(_ data: Data,
                                       jobNeeds: (String) -> String? = { _ in nil }) -> [ClaudeBackgroundSession]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard (row["kind"] as? String) == "background",
                  let id = row["id"] as? String, isJobID(id),
                  let sessionID = nonEmpty(row["sessionId"] as? String) else { return nil }
            return ClaudeBackgroundSession(
                id: id, sessionID: sessionID,
                name: nonEmpty(row["name"] as? String),
                state: nonEmpty(row["state"] as? String),
                needs: nonEmpty(row["waitingFor"] as? String) ?? jobNeeds(id))
        }.sorted { $0.id < $1.id }
    }

    /// The `needs` line from one job's state file, read only to supplement a
    /// CLI entry that lacks `waitingFor`.
    public static func jobNeeds(_ id: String, jobsDirectory: URL = jobsDirectory()) -> String? {
        guard isJobID(id),
              let data = try? Data(contentsOf: jobsDirectory.appendingPathComponent(id).appendingPathComponent("state.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return nonEmpty(object["needs"] as? String)
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
/// `maxAge` has passed. It runs on its own serial queue, one refresh at a
/// time: `current()` never blocks (it returns the cache and starts a refresh
/// when stale), async callers join the refresh already in flight. When the
/// CLI is missing, fails or times out, the jobs files are read instead and a
/// warning is logged once.
public final class ClaudeAgentsSource: @unchecked Sendable {
    public static let shared = ClaudeAgentsSource()

    public typealias Runner = @Sendable () -> Data?
    public typealias Fingerprint = @Sendable () -> String

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "vibebuddy.claude-agents", qos: .utility)
    private let run: Runner
    private let fingerprint: Fingerprint
    private let fallback: @Sendable () -> [ClaudeBackgroundSession]
    private let needs: @Sendable (String) -> String?
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var cached: [ClaudeBackgroundSession] = []
    private var lastRun: Date?
    private var lastFingerprint: String?
    private var inFlight = false
    private var waiters: [CheckedContinuation<[ClaudeBackgroundSession], Never>] = []
    private var warnedFallback = false
    private var runs = 0
    /// Commands actually run. Exposed for tests.
    public var runCount: Int { lock.lock(); defer { lock.unlock() }; return runs }

    public init(run: Runner? = nil,
                fingerprint: Fingerprint? = nil,
                fallback: (@Sendable () -> [ClaudeBackgroundSession])? = nil,
                needs: (@Sendable (String) -> String?)? = nil,
                maxAge: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.run = run ?? { ClaudeAgentsSource.runCLI() }
        self.fingerprint = fingerprint ?? { ClaudeAgentsSource.jobsFingerprint() }
        self.fallback = fallback ?? { ClaudeBackgroundSessions.loadFromJobsDirectory() }
        self.needs = needs ?? { ClaudeBackgroundSessions.jobNeeds($0) }
        self.maxAge = maxAge
        self.now = now
    }

    /// The cached list, immediately. A stale cache starts a refresh in the
    /// background; the next call sees its result.
    public func current() -> [ClaudeBackgroundSession] {
        let print = fingerprint()
        lock.lock()
        let value = cached
        let stale = isStale(print)
        lock.unlock()
        if stale { startRefresh(print, waiter: nil) }
        return value
    }

    /// The list, after a refresh when the cache is stale. Joins a refresh
    /// already in flight rather than starting another.
    public func currentFresh() async -> [ClaudeBackgroundSession] {
        let print = fingerprint()
        let (stale, value) = lock.withLock { (isStale(print) || inFlight, cached) }
        guard stale else { return value }
        return await withCheckedContinuation { startRefresh(print, waiter: $0) }
    }

    /// A refresh now, whatever the cache says (or the one in flight).
    @discardableResult
    public func refreshNow() async -> [ClaudeBackgroundSession] {
        let print = fingerprint()
        return await withCheckedContinuation { startRefresh(print, waiter: $0) }
    }

    private func isStale(_ print: String) -> Bool {
        let fresh = lastRun.map { now().timeIntervalSince($0) < maxAge } ?? false
        return !fresh || print != lastFingerprint
    }

    private func startRefresh(_ print: String, waiter: CheckedContinuation<[ClaudeBackgroundSession], Never>?) {
        lock.lock()
        if let waiter { waiters.append(waiter) }
        guard !inFlight else { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        queue.async { [self] in
            let parsed = run().flatMap { ClaudeBackgroundSessions.parseAgentsJSON($0, jobNeeds: needs) }
            let result = parsed ?? fallback()
            lock.lock()
            runs += 1
            lastRun = now()
            lastFingerprint = print
            cached = result
            inFlight = false
            let ready = waiters
            waiters = []
            let warn = parsed == nil && !warnedFallback
            if warn { warnedFallback = true }
            lock.unlock()
            if warn {
                FileHandle.standardError.write(Data("vibebuddy: `claude agents --json` unavailable; reading ~/.claude/jobs (not a stable interface)\n".utf8))
            }
            ready.forEach { $0.resume(returning: result) }
        }
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

    /// `claude agents --json --all`, bounded; nil on any failure. Every wait
    /// is on the termination handler with a limit, never `waitUntilExit()`: a
    /// CLI stuck in uninterruptible I/O outlives SIGKILL and would otherwise
    /// block the serial queue and every waiter behind it. Stdout is read here,
    /// under the same deadline, and closed before returning: a blocking read on
    /// another thread would leak that thread and the fd whenever the CLI, or a
    /// grandchild holding stdout, never closes it.
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
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // TERM, a second's grace, then KILL; `isRunning` guards both signals, so
        // an exited child's PID, which may be reused, is never signalled.
        func stop() {
            if process.isRunning { process.terminate() }
            guard exited.wait(timeout: .now() + 1) == .timedOut else { return }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = exited.wait(timeout: .now() + 2)
        }
        let deadline = DispatchTime.now() + timeout
        let collected = readToEnd(out.fileHandleForReading.fileDescriptor, deadline: deadline)
        try? out.fileHandleForReading.close()
        guard let collected else { stop(); return nil }
        // Stdout closed; the exit normally follows at once.
        if exited.wait(timeout: max(deadline, .now() + 1)) == .timedOut { stop(); return nil }
        return process.terminationStatus == 0 ? collected : nil
    }

    /// Everything on `descriptor` up to end of file, or nil on an error or at
    /// `deadline`. `poll()` bounds each wait, so `read()` never blocks.
    private static func readToEnd(_ descriptor: Int32, deadline: DispatchTime) -> Data? {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let now = DispatchTime.now()
            guard now < deadline else { return nil }
            let milliseconds = (deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000
            var descriptors = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
            let ready = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), Int32(clamping: max(1, milliseconds)))
            }
            if ready == 0 { return nil }
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return data }
            data.append(bytes, count: count)
        }
    }
}
