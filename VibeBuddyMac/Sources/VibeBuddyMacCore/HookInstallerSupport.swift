import CryptoKit
import Foundation
import VibeBuddyKit

/// The CLIs the hook installer can wire. Raw values are the names the
/// installer's output, `vibebuddyd hooks --agent` and `EnvironmentDetector`
/// use.
public enum HookAgent: String, CaseIterable, Sendable, Codable {
    case claude, codex, grok, antigravity, opencode, cursor

    /// CLIs with a blocking phone-approval gate (`--approval`).
    public var supportsApproval: Bool { [.claude, .codex, .grok, .cursor].contains(self) }

    /// The Settings rows speak `AgentKind`; map one onto the installer's list.
    public init?(_ kind: AgentKind) {
        switch kind {
        case .claudeCode: self = .claude
        case .codex: self = .codex
        case .grok: self = .grok
        case .cursor: self = .cursor
        default: return nil
        }
    }
}

/// A Claude Code release, compared numerically.
public struct ClaudeCodeVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    /// The first `x.y.z` in text such as `2.1.280 (Claude Code)`.
    public init?(parsing text: String) {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3) else { return nil }
        self.init(major, minor, patch)
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// `VIBEBUDDY_CLAUDE_VERSION` wins (air-gapped installs, tests); otherwise
    /// run the installed `claude --version`, bounded so a wedged binary can
    /// never hang an install. Nil when there is no binary or no answer.
    public static func probe(environment: [String: String], home: URL,
                             timeout: TimeInterval = 5) -> ClaudeCodeVersion? {
        if let override = environment["VIBEBUDDY_CLAUDE_VERSION"] {
            return ClaudeCodeVersion(parsing: override)
        }
        guard let binary = ClaudeExecutable.resolve(environment: environment, home: home) else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        process.environment = ClaudeExecutable.runEnvironment(for: binary, environment: environment, home: home)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        return ClaudeCodeVersion(parsing: String(decoding: output, as: UTF8.self))
    }
}

/// Everything the installer reads from the outside world, injectable so tests
/// and smoke runs never touch the real home directory.
public struct HookInstallerEnvironment: Sendable {
    public var home: URL
    /// `~/Library/Application Support/vibebuddy` unless `VIBEBUDDY_SUPPORT_DIR`
    /// says otherwise. Holds the stable `bin/`, the manifest, the remembered
    /// uninstall, backups, and the saved original status line.
    public var supportDirectory: URL
    /// Environment variables: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`,
    /// `CURSOR_HOME`, `XDG_CONFIG_HOME`.
    public var variables: [String: String]
    /// The installed Claude Code version, nil when unknown.
    public var claudeVersion: @Sendable () -> ClaudeCodeVersion?
    public var now: @Sendable () -> Date

    public init(home: URL, supportDirectory: URL? = nil, variables: [String: String] = [:],
                claudeVersion: (@Sendable () -> ClaudeCodeVersion?)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.variables = variables
        if let supportDirectory {
            self.supportDirectory = supportDirectory
        } else if let custom = variables["VIBEBUDDY_SUPPORT_DIR"], !custom.isEmpty {
            self.supportDirectory = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            self.supportDirectory = home.appendingPathComponent("Library/Application Support/vibebuddy", isDirectory: true)
        }
        let probeVariables = variables
        self.claudeVersion = claudeVersion ?? { ClaudeCodeVersion.probe(environment: probeVariables, home: home) }
        self.now = now
    }

    /// The real user: this process's environment, and `$HOME` when set — the
    /// agent CLIs resolve their config from `$HOME`, while Foundation's home
    /// directory ignores it (a `HOME=/tmp/x vibebuddyd hooks …` run must
    /// never reach the real home).
    public static func live(variables: [String: String] = ProcessInfo.processInfo.environment) -> HookInstallerEnvironment {
        let home = variables["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return HookInstallerEnvironment(home: home, variables: variables)
    }
}

/// Where each CLI keeps the file vibebuddy edits, honouring the same
/// environment overrides the CLIs themselves honour.
public struct HookPaths: Sendable {
    public let environment: HookInstallerEnvironment

    public init(_ environment: HookInstallerEnvironment) { self.environment = environment }

    private func directory(_ variable: String, default relative: String) -> URL {
        if let value = environment.variables[variable], !value.isEmpty {
            let expanded = value.hasPrefix("~/")
                ? environment.home.appendingPathComponent(String(value.dropFirst(2))).path
                : value
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return environment.home.appendingPathComponent(relative, isDirectory: true)
    }

    public var claudeDirectory: URL { directory("CLAUDE_CONFIG_DIR", default: ".claude") }
    public var claudeSettings: URL { claudeDirectory.appendingPathComponent("settings.json") }
    public var codexDirectory: URL { directory("CODEX_HOME", default: ".codex") }
    public var codexHooks: URL { codexDirectory.appendingPathComponent("hooks.json") }
    public var codexConfig: URL { codexDirectory.appendingPathComponent("config.toml") }
    /// The shared app-server's control socket, asked (read-only) about trust.
    public var codexControlSocket: URL { codexDirectory.appendingPathComponent("app-server-control/app-server-control.sock") }
    public var grokDirectory: URL { directory("GROK_HOME", default: ".grok") }
    public var grokHooks: URL { grokDirectory.appendingPathComponent("hooks/vibebuddy.json") }
    /// Grok's own settings, where `[ui.status_line]` lives.
    public var grokConfig: URL { grokDirectory.appendingPathComponent("config.toml") }
    public var cursorDirectory: URL { directory("CURSOR_HOME", default: ".cursor") }
    public var cursorHooks: URL { cursorDirectory.appendingPathComponent("hooks.json") }
    public var opencodeDirectory: URL {
        directory("XDG_CONFIG_HOME", default: ".config").appendingPathComponent("opencode", isDirectory: true)
    }
    public var opencodePlugin: URL { opencodeDirectory.appendingPathComponent("plugins/vibebuddy.js") }
    public var antigravityDirectory: URL { environment.home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true) }
    public var antigravityHooks: URL { antigravityDirectory.appendingPathComponent("hooks.json") }

    /// Presence of this path means the CLI is set up on this Mac. A directory,
    /// not a settings file: a fresh Claude Code or Codex install has its home
    /// directory long before it writes a settings file.
    public func configMarker(_ agent: HookAgent) -> URL {
        switch agent {
        case .claude: return claudeDirectory
        case .codex: return codexDirectory
        case .grok: return grokDirectory
        case .antigravity: return antigravityDirectory
        case .opencode: return opencodeDirectory
        case .cursor: return cursorDirectory
        }
    }

    /// The file vibebuddy's entries live in.
    public func hookFile(_ agent: HookAgent) -> URL {
        switch agent {
        case .claude: return claudeSettings
        case .codex: return codexHooks
        case .grok: return grokHooks
        case .antigravity: return antigravityHooks
        case .opencode: return opencodePlugin
        case .cursor: return cursorHooks
        }
    }

    public var support: URL { environment.supportDirectory }
    /// The stable copy of the runtime hook scripts every config points at.
    public var bin: URL { support.appendingPathComponent("bin", isDirectory: true) }
    public var manifest: URL { support.appendingPathComponent("hooks-manifest.json") }
    public var state: URL { support.appendingPathComponent("hooks-state.json") }
    public var backups: URL { support.appendingPathComponent("backups", isDirectory: true) }

    /// A short, stable id for one config file (first 12 hex digits of the
    /// SHA-256 of its canonical path), so two Claude config directories
    /// never share a saved status line, a backup rotation or a manifest entry
    /// — and one directory reached two ways (a `~/.claude` symlink and
    /// `CLAUDE_CONFIG_DIR` naming its target) gets one id, not two.
    public func configKey(_ url: URL) -> String { Self.digest(Self.canonicalPath(url)) }

    /// The key #266 wrote, from the standardized path without resolving
    /// symlinks; read only to carry a saved status line over.
    func unresolvedConfigKey(_ url: URL) -> String { Self.digest(url.standardizedFileURL.path) }

    private static func digest(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// `url` with every symlink resolved, including in the parents of a file
    /// that does not exist yet (`resolvingSymlinksInPath` leaves a path with
    /// a missing leaf untouched): realpath(3) on the deepest existing
    /// ancestor, then the missing components appended. The result is never
    /// standardized again: that strips `/private` only from paths that exist,
    /// so a config's key would change the moment an uninstall deletes it.
    static func canonicalPath(_ url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                return missing.reversed().reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return url.standardizedFileURL.path }
            missing.append(ancestor.lastPathComponent)
            ancestor = parent
        }
    }

    /// Manifest and remembered-uninstall key: the agent plus its canonical config path.
    public func entryKey(_ agent: HookAgent) -> String {
        "\(agent.rawValue):\(Self.canonicalPath(hookFile(agent)))"
    }

    /// A stored manifest or uninstall key in today's form: a bare agent name
    /// (written by b95d7ce9, before keys named the config) takes `config`, or
    /// this environment's config file when there is none; any path is
    /// canonicalized. Keys that name no agent are returned unchanged.
    func normalizedEntryKey(_ key: String, config: String? = nil) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard let agent = parts.first.flatMap(HookAgent.init(rawValue:)) else { return key }
        let path = parts.count == 2 ? parts[1] : (config ?? hookFile(agent).path)
        return "\(agent.rawValue):\(Self.canonicalPath(URL(fileURLWithPath: path)))"
    }

    public var claudeKey: String { configKey(claudeSettings) }
    /// `~/.claude`, the only directory the unkeyed pre-C-1 files belonged to.
    public var isDefaultClaudeDirectory: Bool {
        Self.canonicalPath(claudeDirectory) == Self.canonicalPath(environment.home.appendingPathComponent(".claude"))
    }
    /// The status line saved for *this* Claude config directory.
    public var statusLineOriginal: URL { support.appendingPathComponent("statusline-original.\(claudeKey).json") }
    public var statusLineOriginalCommand: URL { support.appendingPathComponent("statusline-original.\(claudeKey).cmd") }
    /// The same files under #266's unresolved keys — this config path's, and
    /// `~/.claude`'s when that is this directory through a symlink — where
    /// they differ from today's key; empty for a path with no symlink in it.
    var unresolvedKeyStatusLineOriginals: [(json: URL, command: URL)] {
        var settings = [claudeSettings]
        if isDefaultClaudeDirectory { settings.append(environment.home.appendingPathComponent(".claude/settings.json")) }
        var keys: [String] = []
        for key in settings.map(unresolvedConfigKey) where key != claudeKey && !keys.contains(key) { keys.append(key) }
        return keys.map { (support.appendingPathComponent("statusline-original.\($0).json"),
                           support.appendingPathComponent("statusline-original.\($0).cmd")) }
    }
    /// The unkeyed files the Python installer (and scripts from older app
    /// builds) used; read for `~/.claude` only.
    public var legacyStatusLineOriginal: URL { support.appendingPathComponent("statusline-original.json") }
    public var legacyStatusLineOriginalCommand: URL { support.appendingPathComponent("statusline-original.cmd") }

    public var grokKey: String { configKey(grokConfig) }
    /// The `[ui.status_line]` table saved for *this* Grok home (JSON, nil
    /// section when there was none) and the command the wrapper runs.
    public var grokStatusLineOriginal: URL { support.appendingPathComponent("grok-statusline-original.\(grokKey).json") }
    public var grokStatusLineOriginalCommand: URL { support.appendingPathComponent("grok-statusline-original.\(grokKey).cmd") }

    public func script(_ name: String) -> URL { bin.appendingPathComponent(name) }
}

// MARK: - Shell words

/// POSIX `shlex.split` for recognising our own commands: quotes and
/// backslashes, nothing else. Nil for an unterminated quote.
enum ShellWords {
    static func split(_ command: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var iterator = command.makeIterator()
        while let c = iterator.next() {
            if let q = quote {
                if c == q { quote = nil; continue }
                if q == "\"", c == "\\" {
                    guard let next = iterator.next() else { return nil }
                    if "\\\"$`\n".contains(next) { if next != "\n" { word.append(next) } }
                    else { word.append("\\"); word.append(next) }
                    continue
                }
                word.append(c)
                continue
            }
            switch c {
            case " ", "\t", "\n", "\r":
                if inWord { words.append(word); word = ""; inWord = false }
            case "'", "\"":
                quote = c; inWord = true
            case "\\":
                guard let next = iterator.next() else { return nil }
                if next != "\n" { word.append(next) }
                inWord = true
            default:
                word.append(c); inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { words.append(word) }
        return words
    }

    /// `"path"` — the quoting every installer writes around a script path.
    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`") + "\""
    }
}

// MARK: - File plumbing

/// Backups, atomic writes and the small state files. Every config write goes
/// through `write(_:to:agent:)`: back up the current bytes (timestamped),
/// write a temporary file beside the target, rename it over the target.
struct HookFileStore {
    let paths: HookPaths
    var fileManager: FileManager { .default }

    static let maximumBackupsPerFile = 10

    func read(_ url: URL) -> Data? { fileManager.contents(atPath: url.path) }

    func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    /// Copy the current file to `backups/<agent>-<config key>/<name>.<UTC
    /// timestamp>-<counter>` and keep only the newest few; the very first copy
    /// of each config (`<name>.first`, the file as it was before vibebuddy
    /// ever wrote it) is kept for good. Returns the timestamped copy.
    @discardableResult
    func backup(_ url: URL, agent: HookAgent) throws -> URL? {
        guard let data = read(url) else { return nil }
        let directory = paths.backups.appendingPathComponent("\(agent.rawValue)-\(paths.configKey(url))", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let name = url.lastPathComponent
        let first = directory.appendingPathComponent("\(name).first")
        if !exists(first) { try Self.atomicWrite(data, to: first, permissions: 0o600) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: paths.environment.now())
        var counter = 1
        var target: URL
        repeat {
            target = directory.appendingPathComponent("\(name).\(stamp)-\(String(format: "%03d", counter))")
            counter += 1
        } while exists(target)
        try Self.atomicWrite(data, to: target, permissions: 0o600)
        let rotating = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(name + ".") && $0 != first.lastPathComponent }
            .sorted()
        for stale in rotating.dropLast(Self.maximumBackupsPerFile) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(stale))
        }
        return target
    }

    /// Back up, then atomically replace. A symlinked config (dotfile repos)
    /// is written through the link rather than replaced by a plain file.
    func write(_ data: Data, to url: URL, agent: HookAgent, permissions: Int = 0o600) throws -> URL? {
        let target = url.resolvingSymlinksInPath()
        let backup = try backup(target, agent: agent)
        let existing = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
        try Self.atomicWrite(data, to: target, permissions: existing ?? permissions)
        return backup
    }

    func remove(_ url: URL, agent: HookAgent) throws -> URL? {
        let backup = try backup(url.resolvingSymlinksInPath(), agent: agent)
        try fileManager.removeItem(at: url)
        return backup
    }

    static func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).vibebuddy-\(UUID().uuidString)")
        do {
            try data.write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path,
                    NSLocalizedDescriptionKey: "rename failed: \(String(cString: strerror(errno)))"])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// What the installer wrote, per agent *and config path* (`HookPaths.entryKey`,
/// e.g. `claude:/Users/me/.claude-work/settings.json`), so it can recognise its own entries
/// even after the command shape changes, and so status can say what is there.
struct HookManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var config: String
        var commands: [String]
        var approval: Bool
        var installedAt: Date
    }
    var version = 1
    var agents: [String: Entry] = [:]

    var allCommands: Set<String> { Set(agents.values.flatMap(\.commands)) }
}

/// Agents (by `HookPaths.entryKey`) the user explicitly uninstalled. Launches and updates read it and
/// never bring those hooks back; an explicit install clears the agent again.
struct HookInstallState: Codable, Equatable {
    var uninstalled: [String] = []
    var updatedAt: Date?
}

extension HookFileStore {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The manifest with every key in today's form (`HookPaths.normalizedEntryKey`).
    /// When two stored keys name the same config, their commands are merged
    /// (every one stays recognisably ours) and the other fields come from a
    /// path-qualified key over a bare one, then the newer install; the order
    /// is total, so every load gives the same manifest.
    func loadManifest() -> HookManifest {
        var manifest = read(paths.manifest).flatMap { try? Self.decoder.decode(HookManifest.self, from: $0) } ?? HookManifest()
        var agents: [String: HookManifest.Entry] = [:]
        let ordered = manifest.agents.sorted { a, b in
            let (aBare, bBare) = (!a.key.contains(":"), !b.key.contains(":"))
            if aBare != bBare { return aBare }
            if a.value.installedAt != b.value.installedAt { return a.value.installedAt < b.value.installedAt }
            return a.key < b.key
        }
        for (key, entry) in ordered {
            let normalized = paths.normalizedEntryKey(key, config: entry.config)
            var winner = entry
            if let earlier = agents[normalized] {
                winner.commands = Array(Set(earlier.commands + entry.commands)).sorted()
            }
            agents[normalized] = winner
        }
        manifest.agents = agents
        return manifest
    }

    func saveManifest(_ manifest: HookManifest) throws {
        try ensureSupportDirectory()
        try Self.atomicWrite(Self.encoder.encode(manifest), to: paths.manifest, permissions: 0o600)
    }

    func loadState() -> HookInstallState {
        var state = read(paths.state).flatMap { try? Self.decoder.decode(HookInstallState.self, from: $0) } ?? HookInstallState()
        var seen = Set<String>()
        state.uninstalled = state.uninstalled.map { paths.normalizedEntryKey($0) }.filter { seen.insert($0).inserted }
        return state
    }

    func saveState(_ state: HookInstallState) throws {
        try ensureSupportDirectory()
        try Self.atomicWrite(Self.encoder.encode(state), to: paths.state, permissions: 0o600)
    }

    func ensureSupportDirectory() throws {
        try fileManager.createDirectory(at: paths.support, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }
}

// MARK: - Where the runtime scripts come from

/// The directory holding the runtime hook scripts, for callers without an app
/// bundle of their own (`vibebuddyd hooks`). The scripts must come from the
/// same build as the binary writing the configs, so the order follows the
/// running executable, not whatever else happens to be installed:
///
/// 1. an explicit directory (`--hooks-dir`), then `VIBEBUDDY_HOOKS_DIR`;
/// 2. the app bundle enclosing this executable;
/// 3. a checkout's `hooks/` above the executable (`swift run` builds live in
///    `<checkout>/VibeBuddyMac/.build/…`);
/// 4. only for a binary with neither — copied somewhere on its own — the
///    installed `/Applications/VibeBuddyMacApp.app`, then a checkout above
///    the working directory.
///
/// Before C-1b the installed app came before the executable's own checkout,
/// so `vibebuddyd hooks install` from a newer checkout copied an older app's
/// scripts into `bin/` (C-1 review W1). The app still refreshes `bin/` from
/// its own bundle on launch, so each writer leaves its own scripts. Nil when
/// none has the scripts; the installer then relies on an existing `bin/` copy.
public enum HookScriptSource {
    public static func locate(explicit: String? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              executable: URL? = Bundle.main.executableURL,
                              workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                              bundleResources: URL? = Bundle.main.resourceURL,
                              installedApp: URL? = URL(fileURLWithPath: "/Applications/VibeBuddyMacApp.app/Contents/Resources")) -> URL? {
        func valid(_ url: URL) -> Bool {
            HookInstaller.runtimeScripts.allSatisfy {
                FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
            }
        }
        func bundled(_ resources: URL?) -> URL? {
            guard let candidate = resources?.appendingPathComponent("hooks", isDirectory: true) else { return nil }
            return valid(candidate) ? candidate : nil
        }
        func checkout(above start: URL) -> URL? {
            var directory = start
            for _ in 0..<8 {
                let candidate = directory.appendingPathComponent("hooks", isDirectory: true)
                if valid(candidate) { return candidate }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
            return nil
        }
        if let explicit {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
            return valid(url) ? url : nil
        }
        if let variable = environment["VIBEBUDDY_HOOKS_DIR"], !variable.isEmpty {
            let url = URL(fileURLWithPath: (variable as NSString).expandingTildeInPath, isDirectory: true)
            if valid(url) { return url }
        }
        if let own = bundled(bundleResources) { return own }
        if let executable, let own = checkout(above: executable.resolvingSymlinksInPath().deletingLastPathComponent()) {
            return own
        }
        return bundled(installedApp) ?? checkout(above: workingDirectory)
    }

    /// The installed app's hooks directory when `source` is not that app and
    /// its runtime scripts differ from the app's: an install from a checkout
    /// then replaces the scripts every agent on this Mac runs, until the app
    /// next launches and puts its own back. Nil when they match or there is
    /// no installed app.
    public static func differingInstalledApp(_ source: URL,
                                             installedApp: URL? = URL(fileURLWithPath: "/Applications/VibeBuddyMacApp.app/Contents/Resources")) -> URL? {
        guard let app = installedApp?.appendingPathComponent("hooks", isDirectory: true),
              app.resolvingSymlinksInPath().path != source.resolvingSymlinksInPath().path else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: app.path) else { return nil }
        let differs = (HookInstaller.runtimeScripts + [HookInstaller.opencodePlugin]).contains {
            fm.contents(atPath: source.appendingPathComponent($0).path) != fm.contents(atPath: app.appendingPathComponent($0).path)
        }
        return differs ? app : nil
    }
}
