import Foundation

/// Installs, repairs and removes vibebuddy's hooks in every supported agent
/// CLI — natively, so a Mac without python3 can be wired from Settings or from
/// `vibebuddyd hooks`. It replaces the `hooks/install-*.py` scripts and keeps
/// their tested behaviour, plus the rules learned from comparable apps
/// (hook-installer ticket 01, shipped in PR #266):
///
/// 1. Configs only ever name the stable copy of the runtime scripts in
///    `<support>/bin/`, refreshed from the app bundle (or a checkout) on every
///    install and launch, so the command string — and Codex's trust in it —
///    survives app updates.
/// 2. Every write is backed up (timestamped, under `<support>/backups/`) and
///    atomic; the manifest records what was written.
/// 3. Our entries are recognised by command, legacy bundle and checkout paths
///    included, so an install migrates old entries and uninstall removes only
///    ours.
/// 4. Claude Code only gets the hook events its installed version knows.
/// 5. The status line wrapper never wraps itself.
/// 6. `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`, `CURSOR_HOME` and
///    `XDG_CONFIG_HOME` are honoured.
/// 7. An explicit uninstall is remembered; launches never bring hooks back.
/// 8. Codex's `config.toml` is never written (read only, for a diagnostic),
///    and Cursor's `hooks.json` keeps `"version": 1`.
public struct HookInstaller: Sendable {
    /// The runtime scripts every config points at. They need only sh and curl.
    public static let runtimeScripts = [
        "vibebuddy-forward.sh", "approval-hook.sh", "vibebuddy-statusline.sh",
        "cursor-followup.sh", "capture-terminal.sh",
    ]
    /// Copied into OpenCode's plugin directory rather than referenced.
    public static let opencodePlugin = "opencode/vibebuddy.js"

    public let paths: HookPaths
    /// A directory holding the scripts above (the app bundle's
    /// `Contents/Resources/hooks`, or a checkout's `hooks/`). Nil when only an
    /// already-populated `bin/` is available.
    public let scriptSource: URL?

    var files: HookFileStore { HookFileStore(paths: paths) }

    public init(environment: HookInstallerEnvironment = .live(), scriptSource: URL?) {
        self.paths = HookPaths(environment)
        self.scriptSource = scriptSource
    }

    // MARK: - Detection

    /// CLIs configured on this Mac, by the presence of their home directory.
    public func detectedAgents() -> [HookAgent] {
        HookAgent.allCases.filter { files.exists(paths.configMarker($0)) }
    }

    // MARK: - Stable scripts

    /// Copy the runtime scripts into `<support>/bin/` when they differ, then
    /// verify every one is present and executable. Throws rather than let a
    /// config point at a script that is not there — a missing helper makes
    /// every hook fail open, and every event is lost in silence.
    @discardableResult
    public func refreshStableScripts() throws -> Bool {
        let fm = FileManager.default
        var changed = false
        if let source = scriptSource {
            try fm.createDirectory(at: paths.bin.appendingPathComponent("opencode"), withIntermediateDirectories: true)
            for name in Self.runtimeScripts + [Self.opencodePlugin] {
                let from = source.appendingPathComponent(name)
                guard let data = fm.contents(atPath: from.path) else {
                    throw HookInstallerError.scriptsMissing(from.path)
                }
                let to = paths.bin.appendingPathComponent(name)
                let mode = name.hasSuffix(".sh") ? 0o755 : 0o644
                let current = (try? fm.attributesOfItem(atPath: to.path))?[.posixPermissions] as? Int
                if fm.contents(atPath: to.path) != data || current != mode {
                    try HookFileStore.atomicWrite(data, to: to, permissions: mode)
                    changed = true
                }
            }
        }
        for name in Self.runtimeScripts {
            let path = paths.script(name).path
            guard fm.isExecutableFile(atPath: path) else { throw HookInstallerError.scriptsMissing(path) }
        }
        guard fm.fileExists(atPath: paths.script(Self.opencodePlugin).path) else {
            throw HookInstallerError.scriptsMissing(paths.script(Self.opencodePlugin).path)
        }
        return changed
    }

    /// App launch: keep `bin/` current for hooks the user has installed, and
    /// do nothing at all for hooks they removed. Never edits an agent config.
    public func refreshOnLaunch() -> String? {
        let manifest = files.loadManifest()
        let uninstalled = Set(files.loadState().uninstalled)
        let active = manifest.agents.keys.filter { !uninstalled.contains($0) }
        let referenced = HookAgent.allCases.contains { agent in
            !uninstalled.contains(paths.entryKey(agent)) && referencesBin(agent)
        }
        guard !active.isEmpty || referenced else { return nil }
        do {
            return try refreshStableScripts() ? "refreshed hook scripts in \(paths.bin.path)" : nil
        } catch {
            return "hook scripts are missing: \(error)"
        }
    }

    private func referencesBin(_ agent: HookAgent) -> Bool {
        // Grok's status line wrapper lives in config.toml, beside its hooks file.
        let configs = [paths.hookFile(agent)] + (agent == .grok ? [paths.grokConfig] : [])
        return configs.contains { url in
            files.read(url).map { String(decoding: $0, as: UTF8.self).contains(paths.bin.path) } ?? false
        }
    }

    // MARK: - Operations

    /// Install into `agents`, or every detected CLI when nil. `approval` adds
    /// the blocking phone gate where the CLI has one; an existing gate is kept
    /// either way (only uninstall removes it).
    public func install(_ agents: [HookAgent]? = nil, approval: Bool = false) -> HookInstallReport {
        var report = HookInstallReport()
        let targets = agents ?? detectedAgents()
        if agents == nil {
            report.lines.append("detected: " + (targets.map(\.rawValue).joined(separator: ", ").nonEmpty ?? "(none)"))
            let skipped = HookAgent.allCases.filter { !targets.contains($0) }.map(\.rawValue)
            if !skipped.isEmpty { report.lines.append("not configured (skipped): " + skipped.joined(separator: ", ")) }
        }
        guard !targets.isEmpty else { return report }
        do {
            if try refreshStableScripts() { report.lines.append("hook scripts copied to \(paths.bin.path)") }
        } catch {
            report.failures += 1
            report.lines.append("! \(error) — nothing was changed")
            return report
        }
        var manifest = files.loadManifest()
        var state = files.loadState()
        let context = context(manifest: manifest)
        for agent in targets {
            report.lines.append("")
            report.lines.append("=== \(agent.rawValue) ===")
            do {
                let outcome = try perform(.install(approval: approval && agent.supportsApproval), agent, context)
                report.lines += outcome.lines
                report.touched.append(agent)
                let previous = manifest.agents[paths.entryKey(agent)]
                if previous?.commands != outcome.commands || previous?.approval != outcome.approval
                    || previous?.config != paths.hookFile(agent).path {
                    manifest.agents[paths.entryKey(agent)] = HookManifest.Entry(
                        config: paths.hookFile(agent).path, commands: outcome.commands,
                        approval: outcome.approval, installedAt: paths.environment.now())
                }
                state.uninstalled.removeAll { $0 == paths.entryKey(agent) }
            } catch {
                report.failures += 1
                report.lines.append("! \(agent.rawValue): \(error)")
            }
        }
        persist(manifest: manifest, state: state, into: &report)
        return report
    }

    /// The status line alone (Claude's `statusLine`, Grok's
    /// `[ui.status_line]`): wraps whatever is configured, touches no hooks.
    public func enableStatusLine(_ agent: HookAgent = .claude) -> HookInstallReport {
        var report = HookInstallReport()
        guard agent == .claude || agent == .grok else {
            report.failures += 1
            report.lines.append("! \(agent.rawValue) has no status line vibebuddy can forward")
            return report
        }
        do {
            try refreshStableScripts()
            let outcome = try perform(.statusLine, agent, context(manifest: files.loadManifest()))
            report.lines += outcome.lines
            report.touched = [agent]
            var state = files.loadState()
            state.uninstalled.removeAll { $0 == paths.entryKey(agent) }
            var manifest = files.loadManifest()
            if var entry = manifest.agents[paths.entryKey(agent)] {
                entry.commands = Array(Set(entry.commands + outcome.commands)).sorted()
                manifest.agents[paths.entryKey(agent)] = entry
            } else {
                manifest.agents[paths.entryKey(agent)] = HookManifest.Entry(
                    config: paths.hookFile(agent).path, commands: outcome.commands,
                    approval: false, installedAt: paths.environment.now())
            }
            persist(manifest: manifest, state: state, into: &report)
        } catch {
            report.failures += 1
            report.lines.append("! \(agent.rawValue): \(error)")
        }
        return report
    }

    /// Remove vibebuddy from `agents` (every agent when nil) and remember it.
    public func uninstall(_ agents: [HookAgent]? = nil) -> HookInstallReport {
        var report = HookInstallReport()
        var manifest = files.loadManifest()
        var state = files.loadState()
        let context = context(manifest: manifest)
        for agent in agents ?? HookAgent.allCases {
            do {
                let outcome = try perform(.uninstall, agent, context)
                report.lines.append("\(agent.rawValue): " + outcome.lines.joined(separator: "; "))
                if outcome.changed { report.touched.append(agent) }
                manifest.agents[paths.entryKey(agent)] = nil
                if !state.uninstalled.contains(paths.entryKey(agent)) { state.uninstalled.append(paths.entryKey(agent)) }
            } catch {
                report.failures += 1
                report.lines.append("! \(agent.rawValue): \(error)")
            }
        }
        state.uninstalled.sort()
        persist(manifest: manifest, state: state, into: &report)
        // Once nothing names the stable scripts — no manifest entry for any
        // agent or config directory, and no config visible here — they go too.
        if manifest.agents.isEmpty, !HookAgent.allCases.contains(where: referencesBin),
           files.exists(paths.bin) {
            try? FileManager.default.removeItem(at: paths.bin)
            report.lines.append("removed \(paths.bin.path)")
        }
        return report
    }

    /// Saves only what changed, so a repeated install leaves every file as it was.
    private func persist(manifest: HookManifest, state: HookInstallState, into report: inout HookInstallReport) {
        do {
            if manifest != files.loadManifest() || !files.exists(paths.manifest) { try files.saveManifest(manifest) }
            var state = state
            let previous = files.loadState()
            if state.uninstalled != previous.uninstalled || !files.exists(paths.state) {
                state.updatedAt = paths.environment.now()
                try files.saveState(state)
            }
        } catch {
            report.failures += 1
            report.lines.append("! could not record the installation: \(error)")
        }
    }

    // MARK: - Status

    public func status() -> [HookAgentStatus] {
        let uninstalled = Set(files.loadState().uninstalled)
        let context = context(manifest: files.loadManifest())
        return HookAgent.allCases.map { agent in
            let commands = (try? ourCommands(agent, context)) ?? []
            let binPath = paths.bin.path
            var statusLine: Bool?
            if agent == .claude {
                statusLine = (try? ClaudeHooks(paths: paths, context: context, version: nil)
                    .statusLineWired()) ?? false
            } else if agent == .grok {
                statusLine = GrokStatusLine(paths: paths).isWired()
            }
            return HookAgentStatus(
                agent: agent,
                configPath: paths.hookFile(agent).path,
                configured: files.exists(paths.configMarker(agent)),
                installed: !commands.isEmpty,
                approval: commands.contains { $0.contains("approval-hook.sh") },
                // OpenCode's plugin is a copy, not a reference to bin/.
                usesStablePath: !commands.isEmpty && (agent == .opencode || commands.allSatisfy { $0.contains(binPath) }),
                explicitlyUninstalled: uninstalled.contains(paths.entryKey(agent)),
                statusLineWired: statusLine)
        }
    }

    // MARK: - Dispatch

    enum Operation { case install(approval: Bool), uninstall, statusLine }

    struct Context {
        var knownCommands: Set<String>
        var claudeVersion: @Sendable () -> ClaudeCodeVersion?
    }

    struct Outcome {
        var changed = false
        var lines: [String] = []
        var commands: [String] = []
        var approval = false
    }

    func context(manifest: HookManifest) -> Context {
        Context(knownCommands: manifest.allCommands, claudeVersion: paths.environment.claudeVersion)
    }

    private func perform(_ operation: Operation, _ agent: HookAgent, _ context: Context) throws -> Outcome {
        switch agent {
        case .claude:
            let needsVersion: Bool
            if case .install = operation { needsVersion = true } else { needsVersion = false }
            return try ClaudeHooks(paths: paths, context: context,
                                   version: needsVersion ? context.claudeVersion() : nil).run(operation)
        case .codex: return try CodexHooks(paths: paths, context: context).run(operation)
        case .grok: return try GrokHooks(paths: paths, context: context).run(operation)
        case .cursor: return try CursorHooks(paths: paths, context: context).run(operation)
        case .opencode: return try OpenCodePlugin(paths: paths, context: context).run(operation)
        case .antigravity: return try AntigravityHooks(paths: paths, context: context).run(operation)
        }
    }

    private func ourCommands(_ agent: HookAgent, _ context: Context) throws -> [String] {
        switch agent {
        case .claude: return try ClaudeHooks(paths: paths, context: context, version: nil).ourCommands()
        case .codex: return try CodexHooks(paths: paths, context: context).ourCommands()
        case .grok: return try GrokHooks(paths: paths, context: context).ourCommands()
        case .cursor: return try CursorHooks(paths: paths, context: context).ourCommands()
        case .opencode: return try OpenCodePlugin(paths: paths, context: context).ourCommands()
        case .antigravity: return try AntigravityHooks(paths: paths, context: context).ourCommands()
        }
    }
}

public struct HookInstallReport: Sendable {
    public var lines: [String] = []
    public var failures = 0
    /// Agents whose configuration this run changed or checked.
    public var touched: [HookAgent] = []
    public var text: String {
        lines.drop { $0.isEmpty }.joined(separator: "\n")
    }
}

public struct HookAgentStatus: Sendable, Equatable {
    public let agent: HookAgent
    public let configPath: String
    public let configured: Bool
    /// At least one vibebuddy entry is present.
    public let installed: Bool
    public let approval: Bool
    /// Every vibebuddy entry names the stable `bin/` copy (false for entries
    /// left by an older installer; a repair migrates them).
    public let usesStablePath: Bool
    public let explicitlyUninstalled: Bool
    public let statusLineWired: Bool?

    public var summary: String {
        var parts = [configured ? "configured" : "not configured"]
        parts.append(installed ? (approval ? "hooks installed (approval gate)" : "hooks installed") : "no hooks")
        if installed && !usesStablePath { parts.append("legacy paths — run install to migrate") }
        if let statusLineWired { parts.append(statusLineWired ? "status line wired" : "status line not wired") }
        if explicitlyUninstalled { parts.append("uninstalled by you") }
        return "\(agent.rawValue): " + parts.joined(separator: ", ") + "  (\(configPath))"
    }
}

public enum HookInstallerError: Error, CustomStringConvertible, Sendable {
    case scriptsMissing(String)
    case invalidConfig(String, String)

    public var description: String {
        switch self {
        case .scriptsMissing(let path): return "hook script missing: \(path)"
        case .invalidConfig(let path, let reason): return "cannot safely update \(path): \(reason)"
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Shared JSON helpers

/// Load a JSON object config: absent → empty object; unparseable or not an
/// object → an error, and the file is left alone.
func loadJSONObject(_ url: URL, files: HookFileStore) throws -> (OrderedJSON, existed: Bool) {
    guard let data = files.read(url) else { return (.object([]), false) }
    let value: OrderedJSON
    do { value = try OrderedJSON.parse(data) } catch {
        throw HookInstallerError.invalidConfig(url.path, "\(error)")
    }
    guard value.isObject else { throw HookInstallerError.invalidConfig(url.path, "root must be an object") }
    return (value, true)
}

/// Write only when the document actually changed, so a repeat install is a
/// true no-op (no backup, no rewrite, no new mtime).
func writeIfChanged(_ value: OrderedJSON, original: OrderedJSON, existed: Bool, to url: URL,
                    agent: HookAgent, files: HookFileStore, lines: inout [String]) throws -> Bool {
    guard value != original || !existed else { return false }
    let data = value.serialized()
    _ = try OrderedJSON.parse(data)  // never leave a file we cannot read back
    if let backup = try files.write(data, to: url, agent: agent) {
        lines.append("backup: \(backup.path)")
    }
    return true
}

/// The `hooks` array of a hook group, as command strings.
func commands(in group: OrderedJSON) -> [String] {
    (group["hooks"]?.elements ?? []).compactMap { $0["command"]?.stringValue }
}

/// A group with the matching hooks removed; nil when no hook is left.
func strip(_ group: OrderedJSON, where isOurs: (OrderedJSON) -> Bool) -> OrderedJSON? {
    guard let hooks = group["hooks"]?.elements else { return group }
    let kept = hooks.filter { !isOurs($0) }
    guard kept.count != hooks.count else { return group }
    guard !kept.isEmpty else { return nil }
    var copy = group
    copy["hooks"] = .array(kept)
    return copy
}

func groupContains(_ group: OrderedJSON, where isOurs: (OrderedJSON) -> Bool) -> Bool {
    (group["hooks"]?.elements ?? []).contains(where: isOurs)
}
