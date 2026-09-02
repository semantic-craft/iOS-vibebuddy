import Foundation

/// One CLI to look for, where its main config proves it is configured, and an
/// optional separate lifecycle-hook file to inspect for VibeBuddy's marker.
public struct CLISpec: Sendable, Equatable {
    public let name: String
    public let configPath: String
    public let hookPath: String?
    public init(name: String, configPath: String, hookPath: String? = nil) {
        self.name = name
        self.configPath = configPath
        self.hookPath = hookPath
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

    /// The CLIs vibebuddy can wire, mirroring `hooks/install-agent-hooks.py`'s list.
    public static func defaultCLIs(home: String = NSHomeDirectory()) -> [CLISpec] {
        [
            CLISpec(name: "claude",      configPath: "\(home)/.claude/settings.json"),
            CLISpec(name: "codex",       configPath: "\(home)/.codex/config.toml",
                    hookPath: "\(home)/.codex/hooks.json"),
            CLISpec(name: "qwen",        configPath: "\(home)/.qwen/settings.json"),
            CLISpec(name: "grok",        configPath: "\(home)/.grok"),
            CLISpec(name: "antigravity", configPath: "\(home)/.gemini/antigravity-cli"),
            CLISpec(name: "kimi",        configPath: "\(home)/.kimi-code/config.toml"),
            CLISpec(name: "opencode",    configPath: "\(home)/.config/opencode"),
        ]
    }

    public static func detect(_ clis: [CLISpec], fileManager fm: FileManager = .default) -> [CLIHookStatus] {
        clis.map { spec in
            let configured = fm.fileExists(atPath: spec.configPath)
            let injected = configured && markerPresent(at: spec.hookPath ?? spec.configPath, fileManager: fm)
            return CLIHookStatus(name: spec.name, configPath: spec.configPath,
                                 configured: configured, hookInjected: injected)
        }
    }

    /// True when any vibebuddy marker appears in the config — a file, or any file
    /// inside a config dir (plugin layouts). Best-effort: unreadable files are skipped.
    static func markerPresent(at path: String, fileManager fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        let files: [String] = isDir.boolValue
            ? (fm.subpaths(atPath: path) ?? []).map { "\(path)/\($0)" }
            : [path]
        for f in files {
            guard let content = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            if hookMarkers.contains(where: content.contains) { return true }
        }
        return false
    }
}
