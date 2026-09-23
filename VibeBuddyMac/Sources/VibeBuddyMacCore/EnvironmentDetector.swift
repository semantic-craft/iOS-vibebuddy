import Foundation

/// One CLI to look for, where its main config proves it is configured, and an
/// optional separate lifecycle-hook file to inspect for VibeBuddy's marker.
public struct CLISpec: Sendable, Equatable {
    public let name: String
    public let configPath: String
    public let hookPath: String?
    /// The JSON file whose `statusLine.command` should name vibebuddy's
    /// forwarder. Claude Code alone has one, and it is the only source of its
    /// account quota, so it is worth reporting separately from the lifecycle
    /// hooks: the two can be wired independently and one can go missing while
    /// the other keeps working.
    public let statusLinePath: String?
    public init(name: String, configPath: String, hookPath: String? = nil, statusLinePath: String? = nil) {
        self.name = name
        self.configPath = configPath
        self.hookPath = hookPath
        self.statusLinePath = statusLinePath
    }
}

/// Onboarding diagnostic for one CLI: is it configured at all, and is the
/// vibebuddy hook injected? (issue 05). Drives the first-run "your environment
/// is wired correctly" check and the installer's per-CLI rows (issue 06).
public struct CLIHookStatus: Sendable, Equatable {
    public let name: String
    public let configPath: String
    /// The CLI's config file/dir exists (so it's plausibly installed).
    public let configured: Bool
    /// A vibebuddy hook marker is present in that config.
    public let hookInjected: Bool
    /// Whether this CLI's status line forwards to vibebuddy. Nil for a CLI
    /// that has no status line to wire.
    public let statusLineWired: Bool?

    public init(name: String, configPath: String, configured: Bool,
                hookInjected: Bool, statusLineWired: Bool? = nil) {
        self.name = name
        self.configPath = configPath
        self.configured = configured
        self.hookInjected = hookInjected
        self.statusLineWired = statusLineWired
    }
}

/// Detects which agent CLIs are configured and whether vibebuddy's hook is wired
/// into each — a Swift, read-only health check (concept borrowed from
/// open-vibe-island's `HookHealthCheck`; original implementation). Injection
/// is `HookInstaller`'s job; this only *reads*. Terminal-app availability is detected separately in the app via
/// `NSWorkspace` (not here, to keep this pure and testable).
public enum EnvironmentDetector {
    /// Substrings vibebuddy's installers (current and past) leave in a CLI config:
    /// the script names, the early inline-curl endpoint and the OpenCode plugin
    /// header. Deliberately not a bare `/hook`, which matches any user path
    /// under a `hooks/` directory, and not the status line wrapper, which is
    /// reported on its own (`statusLineWired`). A format-agnostic scan.
    public static let hookMarkers = [
        "vibebuddy-forward.sh",
        "approval-hook.sh",
        "capture-terminal.sh",
        "cursor-followup.sh",
        "127.0.0.1:9876/hook",        // the early inline-curl hooks
        "VibeBuddy OpenCode plugin",  // the OpenCode plugin's header
    ]

    /// The status line wrapper the Claude installer writes. Same boundary the
    /// installer's `is_statusline_wrapper` uses.
    public static let statusLineMarker = "vibebuddy-statusline.sh"

    /// The CLIs vibebuddy can wire, at the paths `HookInstaller` writes —
    /// the same `HookPaths`, so detection and installation always agree,
    /// environment overrides (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`,
    /// `CURSOR_HOME`, `XDG_CONFIG_HOME`) included.
    public static func defaultCLIs(home: String = NSHomeDirectory(),
                                   environment: [String: String] = [:]) -> [CLISpec] {
        let paths = HookPaths(HookInstallerEnvironment(
            home: URL(fileURLWithPath: home), variables: environment, claudeVersion: { nil }))
        let order: [HookAgent] = [.claude, .codex, .grok, .antigravity, .opencode, .cursor]
        return order.map { agent in
            CLISpec(name: agent.rawValue,
                    configPath: paths.configMarker(agent).path,
                    hookPath: paths.hookFile(agent).path,
                    statusLinePath: agent == .claude ? paths.claudeSettings.path : nil)
        }
    }

    public static func detect(_ clis: [CLISpec], fileManager fm: FileManager = .default) -> [CLIHookStatus] {
        clis.map { spec in
            let configured = fm.fileExists(atPath: spec.configPath)
            let injected = configured && markerPresent(at: spec.hookPath ?? spec.configPath, fileManager: fm)
            let statusLine = spec.statusLinePath.map { statusLineWired(at: $0, fileManager: fm) }
            return CLIHookStatus(name: spec.name, configPath: spec.configPath,
                                 configured: configured, hookInjected: injected,
                                 statusLineWired: statusLine)
        }
    }

    /// Read `statusLine.command` rather than scanning the file: the marker
    /// only means the status line is wired when it is *that* key's command, and
    /// a settings file can name the script elsewhere without forwarding.
    public static func statusLineWired(at path: String, fileManager fm: FileManager) -> Bool {
        guard let data = fm.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else { return false }
        return command.contains(statusLineMarker)
    }

    static func markerPresent(at path: String, fileManager fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return hookMarkers.contains(where: content.contains)
    }
}
