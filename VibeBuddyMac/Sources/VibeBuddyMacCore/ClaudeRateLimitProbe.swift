import Foundation
import VibeBuddyKit

/// Claude's account allowance, asked for rather than waited on.
///
/// The status line carries `rate_limits`, but only the terminal CLI runs a
/// status line; sessions in the Claude desktop app, the IDE extensions and the
/// web never report one (claude-code#41456). This provider runs the CLI once,
/// headless, and reads the `rate_limit_event` it prints in `stream-json`: the
/// same unified five-hour and seven-day windows, from the headers of a real
/// API response.
///
/// The CLI owns the login throughout — it reads and refreshes its own Keychain
/// token — so VibeBuddy never touches Claude credentials. The call is kept as
/// small as the CLI allows (Haiku, no tools, one-character reply, about a
/// quarter of a cent of allowance) and as invisible: an empty working
/// directory with only project settings, so no user hooks or plugins fire, and
/// no session transcript is written for VibeBuddy's own watchers to find.
public struct ClaudeRateLimitProbe: AccountUsageProviding {
    public static let arguments = [
        "-p", ".",
        "--output-format", "stream-json", "--verbose",
        "--max-turns", "1",
        "--model", "haiku",
        "--system-prompt", "Reply with one character.",
        "--tools", "",
        "--setting-sources", "project",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
    ]

    /// What reaches the probe from the app's environment. Everything else is
    /// dropped: an app started from an agent's shell inherits API keys and
    /// `CLAUDE_CODE_*` switches that would bill or reroute the probe.
    static let inheritedVariables = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "CLAUDE_CONFIG_DIR",
        "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
        "https_proxy", "http_proxy", "all_proxy", "no_proxy",
    ]

    private let executable: @Sendable () -> URL?
    private let timeout: TimeInterval

    public init(
        executable: @escaping @Sendable () -> URL? = { ClaudeExecutable.resolve() },
        timeout: TimeInterval = 60
    ) {
        self.executable = executable
        self.timeout = timeout
    }

    public func fetch() async throws -> AccountUsageSnapshot {
        guard let binary = executable() else { throw AccountUsageError.providerUnavailable }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("vibebuddy-claude-probe")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let environment = Self.environment(for: binary)
        let timeout = timeout
        // The supervisor owns the whole process group: a timeout, a cancelled
        // collector or a descendant still holding stdout after `claude` exits
        // ends in SIGTERM→SIGKILL for all of it, never in a hung refresh loop.
        let supervisor = try POSIXCommandSupervisor()
        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        do {
                            return try supervisor.run(executableURL: binary, arguments: Self.arguments,
                                                      environment: environment, workingDirectory: workDir,
                                                      timeout: timeout, outputLimit: 4 * 1024 * 1024).standardOutput
                        } catch POSIXCommandError.timedOut {
                            throw AccountUsageError.timedOut
                        } catch POSIXCommandError.spawnFailed {
                            throw AccountUsageError.providerUnavailable
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw AccountUsageError.unknown
                        }
                    })
                }
            }
        } onCancel: {
            supervisor.cancel()
        }
        return try ClaudeRateLimitEventDecoder.decode(streamJSON: String(decoding: output, as: UTF8.self),
                                                      fetchedAt: Date())
    }

    static func environment(
        for binary: URL,
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var kept = environment.filter { inheritedVariables.contains($0.key) }
        // The CLI finds its Keychain login by the account name in `USER`;
        // without it, it reports signed out.
        if kept["USER"]?.isEmpty ?? true { kept["USER"] = NSUserName() }
        if kept["LOGNAME"]?.isEmpty ?? true { kept["LOGNAME"] = kept["USER"] }
        kept["PATH"] = environment["PATH"]
        // No self-update or telemetry side trips: they add children and time
        // to a call that only needs its response headers.
        kept["DISABLE_AUTOUPDATER"] = "1"
        kept["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return ClaudeExecutable.runEnvironment(for: binary, environment: kept, home: home)
    }
}

/// Pure mapping from the CLI's `stream-json` output onto a Claude snapshot.
///
/// `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed",
/// "rateLimitType":"five_hour","resetsAt":…,"unifiedWindows":{"five_hour":
/// {"utilization":0.01,"resetsAt":…},"seven_day":{…}}}}` — utilization is a
/// fraction and `resetsAt` epoch seconds (CLI 2.1.281). `unifiedWindows` is
/// read into the status line's `rate_limits` shape so both sources name and
/// size windows identically; an event without it still gives its one window.
public enum ClaudeRateLimitEventDecoder {
    public static func decode(streamJSON: String, fetchedAt: Date) throws -> AccountUsageSnapshot {
        var info: [String: Any]?
        var authFailed = false
        var resultError: String?
        for line in streamJSON.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "rate_limit_event":
                info = object["rate_limit_info"] as? [String: Any] ?? info
            case "system" where object["subtype"] as? String == "api_retry":
                if StatusLineSample.int(object["error_status"]) == 401 { authFailed = true }
            case "result" where object["is_error"] as? Bool == true:
                resultError = (object["result"] as? String) ?? (object["terminal_reason"] as? String) ?? "error"
            default:
                break
            }
        }
        if let info, let snapshot = snapshot(from: info, fetchedAt: fetchedAt) { return snapshot }
        if info?["status"] as? String == "rejected" { throw AccountUsageError.rateLimited }
        if authFailed { throw AccountUsageError.notLoggedIn }
        if let resultError { throw AccountUsageError.classify(message: resultError) }
        throw AccountUsageError.incompatibleFormat
    }

    private static func snapshot(from info: [String: Any], fetchedAt: Date) -> AccountUsageSnapshot? {
        var windows = info["unifiedWindows"] as? [String: Any] ?? [:]
        if windows.isEmpty, let type = info["rateLimitType"] as? String, info["utilization"] != nil {
            windows[type] = ["utilization": info["utilization"] as Any, "resetsAt": info["resetsAt"] as Any]
        }
        var limits: [String: Any] = [:]
        for (key, value) in windows {
            guard let window = value as? [String: Any],
                  let utilization = StatusLineSample.double(window["utilization"]) else { continue }
            var entry: [String: Any] = ["used_percentage": min(100, max(0, utilization * 100))]
            if let resets = window["resetsAt"] { entry["resets_at"] = resets }
            limits[key] = entry
        }
        guard !limits.isEmpty else { return nil }
        let sample = StatusLineSample.decode(["session_id": "rate-limit-probe", "rate_limits": limits])
        return sample?.usageSnapshot(fetchedAt: fetchedAt)
    }
}
