import Foundation

/// Where the `claude` binary lives on this Mac. Several features shell out to
/// it (background dispatch, capability probes), so the lookup is shared rather
/// than repeated per call site.
public enum ClaudeExecutable {
    public static func resolve(
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

    /// The environment to run `claude` with from a GUI app: launchd's bare
    /// PATH lacks Homebrew and `~/.local/bin`, and an npm-installed `claude`
    /// is a `#!/usr/bin/env node` script.
    public static func runEnvironment(for binary: URL, environment: [String: String], home: URL) -> [String: String] {
        var variables = environment
        let existing = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let extra = [binary.resolvingSymlinksInPath().deletingLastPathComponent().path,
                     binary.deletingLastPathComponent().path,
                     "/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
        var seen: Set<String> = []
        variables["PATH"] = (extra + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        variables["HOME"] = variables["HOME"] ?? home.path
        return variables
    }
}
