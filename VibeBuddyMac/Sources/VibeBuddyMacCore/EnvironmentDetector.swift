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
/// open-vibe-island's `HookHealthCheck`; original implementation). The actual
/// injection stays in the tested `hooks/install-*.py` installers (issue 06); this
/// only *reads*. Terminal-app availability is detected separately in the app via
/// `NSWorkspace` (not here, to keep this pure and testable).
public enum EnvironmentDetector {
    /// Substrings the vibebuddy installers leave in a CLI config (`hooks/install-*.py`):
    /// the forwarder endpoint and the script hook names. A format-agnostic scan — works
    /// across JSON `settings.json`, TOML `config.toml`, and plugin dirs alike.
    public static let hookMarkers = [
        "/hook",                 // the daemon forward endpoint (MARKER in install-claude-hooks.py)
        "approval-hook.sh",
        "capture-terminal.sh",
        "vibebuddy-forward.sh",
    ]

    /// The status line wrapper the Claude installer writes. Same boundary the
    /// installer's `is_statusline_wrapper` uses.
    public static let statusLineMarker = "vibebuddy-statusline.sh"

    /// The CLIs vibebuddy can wire, mirroring `hooks/install-agent-hooks.py`'s list.
    public static func defaultCLIs(home: String = NSHomeDirectory()) -> [CLISpec] {
        [
            CLISpec(name: "claude",      configPath: "\(home)/.claude/settings.json",
                    statusLinePath: "\(home)/.claude/settings.json"),
            CLISpec(name: "codex",       configPath: "\(home)/.codex/config.toml",
                    hookPath: "\(home)/.codex/hooks.json"),
            CLISpec(name: "grok",        configPath: "\(home)/.grok",
                    hookPath: "\(home)/.grok/hooks/vibebuddy.json"),
            CLISpec(name: "antigravity", configPath: "\(home)/.gemini/antigravity-cli",
                    hookPath: "\(home)/.gemini/antigravity-cli/hooks.json"),
            CLISpec(name: "opencode",    configPath: "\(home)/.config/opencode",
                    hookPath: "\(home)/.config/opencode/plugins/vibebuddy.js"),
            // Cursor is configured by the presence of its own home directory —
            // the IDE and the `cursor-agent` CLI share it — and its lifecycle
            // hooks live in one user-level file beside it.
            CLISpec(name: "cursor",      configPath: "\(home)/.cursor",
                    hookPath: "\(home)/.cursor/hooks.json"),
        ]
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
