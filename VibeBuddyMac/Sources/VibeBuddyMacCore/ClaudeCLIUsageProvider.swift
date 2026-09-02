import Darwin
import Foundation

public enum ClaudeUsageResponseDecoder {
    private struct Envelope: Decodable {
        var isError: Bool
        var result: String

        enum CodingKeys: String, CodingKey {
            case isError = "is_error"
            case result
        }
    }

    public static func decode(
        _ data: Data,
        fetchedAt: Date,
        calendar: Calendar = .current
    ) throws -> AccountUsageSnapshot {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw AccountUsageError.incompatibleFormat
        }
        guard !envelope.isError else {
            throw AccountUsageError.classify(message: envelope.result)
        }

        let primary = try window(
            named: "Current session",
            kind: .primary,
            durationMinutes: 5 * 60,
            in: envelope.result,
            now: fetchedAt,
            calendar: calendar
        )
        let secondary = try window(
            named: "Current week (all models)",
            kind: .secondary,
            durationMinutes: 7 * 24 * 60,
            in: envelope.result,
            now: fetchedAt,
            calendar: calendar
        )
        guard primary != nil || secondary != nil else {
            throw AccountUsageError.incompatibleFormat
        }

        return AccountUsageSnapshot(
            provider: .claude,
            planType: nil,
            primary: primary,
            secondary: secondary,
            lifetimeTokens: nil,
            latestDailyTokens: nil,
            fetchedAt: fetchedAt
        )
    }

    private static func window(
        named name: String,
        kind: AccountUsageWindowKind,
        durationMinutes: Int,
        in output: String,
        now: Date,
        calendar: Calendar
    ) throws -> AccountUsageWindow? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?m)^\(escaped):\\s*([0-9]+(?:\\.[0-9]+)?)% used\\s*·\\s*resets\\s+(.+?)\\s+\\(([^()]+)\\)\\s*$"
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range) else { return nil }
        guard let percentRange = Range(match.range(at: 1), in: output),
              let percent = Double(output[percentRange]),
              percent.isFinite,
              (0...100).contains(percent),
              let resetRange = Range(match.range(at: 2), in: output),
              let zoneRange = Range(match.range(at: 3), in: output),
              let reset = parseReset(
                String(output[resetRange]),
                timeZoneID: String(output[zoneRange]),
                now: now,
                calendar: calendar
              ) else {
            throw AccountUsageError.incompatibleFormat
        }
        return AccountUsageWindow(
            kind: kind,
            usedPercent: Int(percent.rounded()),
            windowDurationMinutes: durationMinutes,
            resetsAt: reset
        )
    }

    private static func parseReset(
        _ value: String,
        timeZoneID: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let timeZone = TimeZone(identifier: timeZoneID) else { return nil }
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        let year = localCalendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.calendar = localCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d 'at' h:mma yyyy"
        guard var candidate = formatter.date(from: "\(value) \(year)") else { return nil }
        if candidate < now.addingTimeInterval(-60) {
            candidate = localCalendar.date(byAdding: .year, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }
}
/// Reads subscription quota through Claude Code's own read-only `/usage`
/// command. Claude remains the sole owner of OAuth and Keychain access.
public final class ClaudeCLIUsageProvider: AccountUsageProviding, @unchecked Sendable {
    private let executableURL: URL?
    private let arguments: [String]
    private let timeout: TimeInterval

    public init(
        executableURL: URL? = nil,
        arguments: [String] = [
            "-p", "/usage",
            "--output-format", "json",
            "--no-session-persistence",
            "--safe-mode",
            "--permission-mode", "dontAsk",
        ],
        timeout: TimeInterval = 15
    ) {
        self.executableURL = executableURL ?? Self.resolveClaudeExecutable()
        self.arguments = arguments
        self.timeout = timeout
    }

    public func fetch() async throws -> AccountUsageSnapshot {
        try Task.checkCancellation()
        guard let executableURL else { throw AccountUsageError.providerUnavailable }
        let supervisor: POSIXCommandSupervisor
        do {
            supervisor = try POSIXCommandSupervisor()
        } catch {
            throw AccountUsageError.providerUnavailable
        }
        let arguments = arguments
        let timeout = timeout
        return try await withTaskCancellationHandler {
            do {
                let data = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result {
                            try Self.run(
                                executableURL: executableURL,
                                arguments: arguments,
                                timeout: timeout,
                                supervisor: supervisor
                            )
                        })
                    }
                }
                try Task.checkCancellation()
                return try ClaudeUsageResponseDecoder.decode(data, fetchedAt: Date())
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            supervisor.cancel()
        }
    }

    public static func resolveClaudeExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let fixed = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/claude" }
        return (fixed + fromPath)
            .first(where: fileManager.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    private static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        supervisor: POSIXCommandSupervisor
    ) throws -> Data {
        guard timeout > 0 else { throw AccountUsageError.timedOut }
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        do {
            let result = try supervisor.run(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                outputLimit: 1_048_576
            )
            guard result.exitedSuccessfully else {
                let message = String(
                    decoding: result.standardError + result.standardOutput,
                    as: UTF8.self
                )
                throw AccountUsageError.classify(message: message)
            }
            return result.standardOutput
        } catch let error as POSIXCommandError {
            switch error {
            case .spawnFailed: throw AccountUsageError.providerUnavailable
            case .timedOut: throw AccountUsageError.timedOut
            case .outputLimitExceeded: throw AccountUsageError.incompatibleFormat
            case .waitFailed: throw AccountUsageError.unknown
            }
        }
    }
}
