import Foundation
import VibeBuddyKit

/// Official read-only command. The CLI owns authentication; VibeBuddy reads no tokens.
public struct AntigravityUsageProvider: AccountUsageProviding {
    private let executable: @Sendable () -> URL?
    private let timeout: TimeInterval

    public init(executable: @escaping @Sendable () -> URL? = { Self.resolveExecutable() }, timeout: TimeInterval = 30) {
        self.executable = executable
        self.timeout = timeout
    }

    public func fetch() async throws -> AccountUsageSnapshot {
        guard let binary = executable() else { throw AccountUsageError.providerUnavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibebuddy-antigravity-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "PATH",
                       "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
                       "https_proxy", "http_proxy", "all_proxy", "no_proxy"]
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        if environment["HOME"] == nil { environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path }
        let inherited = environment
        let timeout = timeout
        let supervisor = try POSIXCommandSupervisor()
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        do {
                            let result = try supervisor.run(executableURL: binary,
                                arguments: ["-p", "/usage", "--output-format", "json"],
                                environment: inherited, workingDirectory: directory,
                                timeout: timeout, outputLimit: 1_048_576)
                            guard result.exitedSuccessfully else {
                                throw AccountUsageError.classify(message: String(decoding: result.standardError, as: UTF8.self))
                            }
                            return result.standardOutput
                        } catch POSIXCommandError.timedOut { throw AccountUsageError.timedOut }
                        catch POSIXCommandError.spawnFailed { throw AccountUsageError.providerUnavailable }
                        catch POSIXCommandError.outputLimitExceeded { throw AccountUsageError.incompatibleFormat }
                    })
                }
            }
        } onCancel: { supervisor.cancel() }
        return try Self.decode(data, fetchedAt: Date())
    }

    public static func resolveExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/agy" }
        return (paths + [home.appendingPathComponent(".local/bin/agy").path, "/opt/homebrew/bin/agy", "/usr/local/bin/agy"])
            .first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    public static func decode(_ data: Data, fetchedAt: Date) throws -> AccountUsageSnapshot {
        struct Response: Decodable {
            struct Command: Decodable {
                struct Usage: Decodable {
                    struct Group: Decodable {
                        struct Bucket: Decodable {
                            let id: String
                            let window: String
                            let remaining_fraction: Double?
                            let reset_time: String?
                        }
                        let name: String
                        let buckets: [Bucket]
                    }
                    let groups: [Group]
                }
                let data: Usage
            }
            let status: String
            let command: Command
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.status == "SUCCESS" else {
            throw AccountUsageError.incompatibleFormat
        }
        let dateParser = ISO8601DateFormatter()
        let windows = response.command.data.groups.flatMap { group in
            group.buckets.compactMap { bucket -> AccountUsageWindow? in
                guard let fraction = bucket.remaining_fraction, fraction.isFinite, (0...1).contains(fraction) else { return nil }
                let minutes: Int?
                switch bucket.window {
                case "weekly": minutes = 10080
                case "5h": minutes = 300
                default: minutes = nil
                }
                return AccountUsageWindow(kind: .extra, usedPercent: 100 - Int((fraction * 100).rounded()),
                    windowDurationMinutes: minutes, resetsAt: bucket.reset_time.flatMap(dateParser.date(from:)),
                    label: "\(group.name) · \(bucket.window)", key: bucket.id, poolKey: group.name)
            }
        }
        guard !windows.isEmpty else { throw AccountUsageError.incompatibleFormat }
        var snapshot = AccountUsageSnapshot(provider: .antigravity, planType: nil, primary: nil, secondary: nil,
            lifetimeTokens: nil, latestDailyTokens: nil, fetchedAt: fetchedAt, extraWindows: windows)
        // Desktop authentication may be different; do not attribute this to the desktop account.
        snapshot.accountLabel = "CLI account"
        return snapshot
    }
}
