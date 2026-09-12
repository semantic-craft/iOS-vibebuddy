import Foundation

/// Explicit, isolated desktop acceptance run. Ordinary launches have no override.
/// Invalid opt-in never falls back to the user's production state.
public struct E2ERunConfiguration: Sendable {
    public let root: URL
    public let id: String
    public let port: Int
    public let notificationsEnabled: Bool
    public let audioEnabled: Bool
    public let host: String
    public let codexThreadID: String?
    public var keychainService: String { "com.vibebuddy.e2e.\(id).secrets" }

    public enum ConfigurationError: Error { case invalidEnvironment }

    public static let current: E2ERunConfiguration? = {
        do {
            return try E2ERunConfiguration(
                environment: ProcessInfo.processInfo.environment,
                bundleIdentifier: Bundle.main.bundleIdentifier)
        } catch {
            fatalError("Invalid VibeBuddy E2E configuration; refusing to access production state.")
        }
    }()

    /// Pure parsing: creates no directories, touches no secrets and starts no services.
    /// Absence is allowed only when none of the E2E variables is present.
    public init?(environment: [String: String], bundleIdentifier: String?) throws {
        let keys = Set(environment.keys.filter { $0.hasPrefix("VIBEBUDDY_E2E_") })
        guard !keys.isEmpty else { return nil }
        let allowed: Set<String> = ["VIBEBUDDY_E2E_ROOT", "VIBEBUDDY_E2E_ID", "VIBEBUDDY_E2E_PORT",
                                    "VIBEBUDDY_E2E_NOTIFICATIONS", "VIBEBUDDY_E2E_AUDIO",
                                    "VIBEBUDDY_E2E_HOST", "VIBEBUDDY_E2E_CODEX_THREAD"]
        guard keys.isSubset(of: allowed),
              let path = environment["VIBEBUDDY_E2E_ROOT"], path.hasPrefix("/"), !path.contains("\0"),
              let id = environment["VIBEBUDDY_E2E_ID"], !id.isEmpty,
              id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              let rawPort = environment["VIBEBUDDY_E2E_PORT"], !rawPort.isEmpty,
              rawPort.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(rawPort), (1024...65535).contains(port), port != 9876,
              bundleIdentifier == "com.vibebuddy.e2e.\(id)" else {
            throw ConfigurationError.invalidEnvironment
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.path != "/" else { throw ConfigurationError.invalidEnvironment }
        for key in ["VIBEBUDDY_E2E_NOTIFICATIONS", "VIBEBUDDY_E2E_AUDIO"] {
            if let value = environment[key], value != "1" { throw ConfigurationError.invalidEnvironment }
        }
        let host = environment["VIBEBUDDY_E2E_HOST"] ?? "127.0.0.1"
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = octets.compactMap { UInt8($0) }
        guard octets.count == 4, numbers.count == 4,
              zip(octets, numbers).allSatisfy({ String($0.0) == String($0.1) }),
              host == "127.0.0.1" || numbers[0] == 10 ||
                (numbers[0] == 100 && (64...127).contains(numbers[1])) ||
                (numbers[0] == 172 && (16...31).contains(numbers[1])) ||
                (numbers[0] == 192 && numbers[1] == 168) else {
            throw ConfigurationError.invalidEnvironment
        }
        let threadID = environment["VIBEBUDDY_E2E_CODEX_THREAD"]
        if let threadID, UUID(uuidString: threadID) == nil {
            throw ConfigurationError.invalidEnvironment
        }
        self.host = host
        self.codexThreadID = threadID
        self.root = root
        self.id = id
        self.port = port
        notificationsEnabled = environment["VIBEBUDDY_E2E_NOTIFICATIONS"] == "1"
        audioEnabled = environment["VIBEBUDDY_E2E_AUDIO"] == "1"
    }

    /// Fixed one-component filenames supplied by storage owners, never user paths.
    public func file(_ name: String) -> URL {
        precondition(!name.isEmpty && name != "." && name != ".." &&
                     !name.contains("/") && !name.contains("\\") && !name.contains("\0"),
                     "E2E storage requires a fixed filename.")
        return root.appendingPathComponent(name)
    }
}
