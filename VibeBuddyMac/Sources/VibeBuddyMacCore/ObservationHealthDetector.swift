import Foundation
import VibeBuddyKit

/// Mac-only configuration diagnosis. Kept outside ObservationHealth so this
/// local setting cannot introduce a new value into the phone snapshot contract.
public enum CodexHookConfigurationIssue: Sendable, Equatable {
    case hooksFeatureDisabled

    public var displayName: String { "Hooks feature disabled" }
    public var explanation: String {
        "Codex hooks are disabled in the user configuration. Run codex features enable hooks, then start a fresh Codex session."
    }
}

/// A runtime signal recorded by `SessionStore`. Event families are accumulated
/// per source, while health and time come from the newest signal.
public struct ObservationRuntimeSignal: Sendable, Equatable {
    public let agent: AgentKind
    public let source: ObservationSource
    public var lastObservedAt: Date
    public var health: ObservationHealth
    public var observedCoverage: [ObservationEventCoverage]

    public init(
        agent: AgentKind,
        source: ObservationSource,
        lastObservedAt: Date,
        health: ObservationHealth = .healthy,
        observedCoverage: [ObservationEventCoverage] = []
    ) {
        self.agent = agent
        self.source = source
        self.lastObservedAt = lastObservedAt
        self.health = health
        self.observedCoverage = Array(Set(observedCoverage)).sorted()
    }
}

/// Read-only compatibility and source health inspection. It never inspects a
/// process list and never mutates hook files or session progress.
public enum ObservationHealthDetector {
    /// Hooks are installed at user level; project and profile overrides are
    /// outside this diagnostic's scope. Never writes the configuration. A fresh
    /// healthy runtime signal takes precedence over the file's static setting.
    public static func codexHookConfigurationIssue(
        home: URL?, hook: ObservationSourceDiagnostic?, now: Date,
        staleAfter: TimeInterval = 10 * 60
    ) -> CodexHookConfigurationIssue? {
        if let hook, hook.health == .healthy, let observed = hook.lastObservedAt,
           now.timeIntervalSince(observed) <= staleAfter { return nil }
        guard let home,
              let data = readData(at: home.appendingPathComponent(".codex/config.toml"),
                                  upToCount: (1 << 20) + 1, fileManager: .default),
              data.count <= 1 << 20, let text = String(data: data, encoding: .utf8)
        else { return nil }
        // Same deliberately narrow scalar scan as install-codex-hooks.py.
        // Skip multiline string bodies: example keys are not settings.
        var table: [String]? = []
        var multiline: String?
        var values: [String: Bool] = [:]
        for raw in text.split(separator: "\n") {
            if let delimiter = multiline {
                if raw.contains(delimiter) { multiline = nil }
                continue
            }
            let line = raw.split(separator: "#", maxSplits: 1,
                                 omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let delimiters = ["\"\"\"", "'''"]
                .compactMap { mark in line.range(of: mark).map { ($0, mark) } }
                .sorted { $0.0.lowerBound < $1.0.lowerBound }
            if let (range, mark) = delimiters.first {
                if !line[range.upperBound...].contains(mark) { multiline = mark }
                continue
            }
            if line.hasPrefix("[") {
                table = line.hasSuffix("]") ? featureKeyPath(String(line.dropFirst().dropLast())) : nil
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard let table, parts.count == 2, let key = featureKeyPath(String(parts[0])) else { continue }
            let path = table + key
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if [["features", "hooks"], ["features", "codex_hooks"]].contains(path),
               ["true", "false"].contains(value), let name = path.last {
                values[name] = value == "true"
            }
        }
        // The canonical key wins over the deprecated alias.
        return (values["hooks"] ?? values["codex_hooks"]) == false ? .hooksFeatureDisabled : nil
    }

    /// Bare or simply quoted TOML components. A quoted key containing a dot
    /// is a literal, not an equivalent dotted path, and does not match here.
    private static func featureKeyPath(_ text: String) -> [String]? {
        var path: [String] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            var token = part.trimmingCharacters(in: .whitespaces)
            if let quote = token.first, quote == "\"" || quote == "'",
               token.count >= 2, token.last == quote {
                token = String(token.dropFirst().dropLast())
            }
            guard token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
            path.append(token)
        }
        return path
    }

    private static let requiredHookCoverage = Set(ObservationEventCoverage.allCases)
    private static let supportedEventMessages: Set<String> = [
        "task_started", "task_complete", "turn_aborted",
        "exec_approval_request", "apply_patch_approval_request",
        "request_user_input", "elicitation_request", "item_completed",
    ]
    private static let supportedResponseItems: Set<String> = [
        "function_call", "custom_tool_call", "local_shell_call", "mcp_tool_call",
        "function_call_output", "custom_tool_call_output", "local_shell_call_output",
    ]

    private enum RolloutInspection {
        case readable(version: String, hasProgress: Bool)
        case invalid(version: String?)
        case unreadable
    }

    public static func detect(
        home: URL?,
        signals: [ObservationRuntimeSignal],
        now: Date,
        staleAfter: TimeInterval = 10 * 60,
        grokHome: URL = GrokHome.url,
        fileManager fm: FileManager = .default
    ) -> [AgentObservationDiagnostic] {
        let claude = agentDiagnostic(
            agent: .claudeCode,
            daemon: statusLineEvidence(
                config: home?.appendingPathComponent(".claude/settings.json"),
                signals: signals,
                now: now,
                staleAfter: staleAfter,
                fileManager: fm),
            hook: hookEvidence(
                config: home?.appendingPathComponent(".claude/settings.json"),
                installMarker: home?.appendingPathComponent(".claude", isDirectory: true),
                agent: .claudeCode,
                signals: signals,
                now: now,
                staleAfter: staleAfter,
                fileManager: fm),
            passive: passiveEvidence(
                root: home?.appendingPathComponent(".claude/projects", isDirectory: true),
                source: .transcript,
                agent: .claudeCode,
                installed: home.map { fm.fileExists(atPath: $0.appendingPathComponent(".claude").path) },
                signals: signals,
                now: now,
                staleAfter: staleAfter,
                fileManager: fm))

        let codexInstalled = home.map {
            fm.fileExists(atPath: $0.appendingPathComponent(".codex/config.toml").path)
                || fm.fileExists(atPath: $0.appendingPathComponent(".codex").path)
        }
        let codex = agentDiagnostic(
            agent: .codex,
            daemon: appServerEvidence(
                socket: home?.appendingPathComponent(".codex/app-server-control/app-server-control.sock"),
                signals: signals,
                now: now,
                staleAfter: staleAfter,
                fileManager: fm),
            hook: hookEvidence(
                config: home?.appendingPathComponent(".codex/hooks.json"),
                installMarker: home?.appendingPathComponent(".codex", isDirectory: true),
                agent: .codex,
                signals: signals,
                now: now,
                staleAfter: staleAfter,
                fileManager: fm),
            passive: passiveEvidence(
                root: home?.appendingPathComponent(".codex/sessions", isDirectory: true),
                source: .rollout,
                agent: .codex,
                installed: codexInstalled,
                signals: signals,
                now: now,
                staleAfter: staleAfter,
                fileManager: fm))

        // Grok keeps standalone hook files under `<grok home>/hooks/*.json`;
        // ours is `vibebuddy.json`. The install marker is the config dir itself
        // — grok 1.0.13 has no single settings file we can rely on. Everything
        // here hangs off the *resolved* grok home (`$GROK_HOME`, else `~/.grok`)
        // so an isolated profile is inspected where its hooks were installed.
        let grok = agentDiagnostic(
            agent: .grok,
            hook: hookEvidence(
                config: grokHome.appendingPathComponent("hooks/vibebuddy.json"),
                installMarker: grokHome,
                agent: .grok,
                signals: signals,
                now: now,
                staleAfter: staleAfter,
                fileManager: fm),
            passive: passiveEvidence(
                root: GrokSessionLocator.sessionsRoot(grokHome: grokHome),
                source: .transcript,
                agent: .grok,
                installed: fm.fileExists(atPath: grokHome.path),
                signals: signals,
                now: now,
                staleAfter: staleAfter,
                fileManager: fm))
        return [claude, codex, grok]
    }

    private static func agentDiagnostic(
        agent: AgentKind,
        daemon: ObservationSourceDiagnostic? = nil,
        hook: ObservationSourceDiagnostic,
        passive: ObservationSourceDiagnostic
    ) -> AgentObservationDiagnostic {
        AgentObservationDiagnostic(agent: agent, sources: [daemon, hook, passive].compactMap { $0 })
    }

    /// Claude's status line forwarder: healthy while samples arrive, awaiting
    /// activity when configured without a sample, "not installed"
    /// when Claude's settings name no vibebuddy status line.
    private static func statusLineEvidence(
        config: URL?,
        signals: [ObservationRuntimeSignal],
        now: Date,
        staleAfter: TimeInterval,
        fileManager fm: FileManager
    ) -> ObservationSourceDiagnostic {
        let signal = latestSignal(agent: .claudeCode, source: .statusline, in: signals)
        var configured = false
        if let config, fm.fileExists(atPath: config.path) {
            guard let data = readData(at: config, upToCount: 1 << 20, fileManager: fm),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return diagnostic(source: .statusline, signal: signal, fallback: .sourceUnreadable,
                                  now: now, staleAfter: staleAfter, forceFallback: true)
            }
            if let statusLine = root["statusLine"] as? [String: Any],
               let command = statusLine["command"] as? String {
                // Keep the existing installer's is_statusline_wrapper boundary;
                // strict executable parsing below is for lifecycle hooks only.
                configured = command.contains("vibebuddy-statusline.sh")
            }
        }
        return diagnostic(source: .statusline, signal: signal,
                          fallback: configured ? .temporarilySilent : .notInstalled,
                          reasonCode: configured ? "awaitingActivity" : "optionalSourceNotConfigured",
                          now: now, staleAfter: staleAfter,
                          forceFallback: !configured && signal == nil)
    }

    /// The Codex app-server daemon: healthy while the monitor's connection
    /// reports, "events missing" when its control socket exists but nothing has
    /// been read from it yet, "not installed" when there is no socket at all.
    private static func appServerEvidence(
        socket: URL?,
        signals: [ObservationRuntimeSignal],
        now: Date,
        staleAfter: TimeInterval,
        fileManager fm: FileManager
    ) -> ObservationSourceDiagnostic {
        let signal = latestSignal(agent: .codex, source: .appserver, in: signals)
        let socketExists = socket.map { fm.fileExists(atPath: $0.path) } ?? false
        return diagnostic(source: .appserver, signal: signal,
                          fallback: socketExists ? .eventsMissing : .notInstalled,
                          now: now, staleAfter: staleAfter,
                          forceFallback: !socketExists && signal == nil)
    }

    private static func hookEvidence(
        config: URL?,
        installMarker: URL? = nil,
        agent: AgentKind,
        signals: [ObservationRuntimeSignal],
        now: Date,
        staleAfter: TimeInterval,
        fileManager fm: FileManager
    ) -> ObservationSourceDiagnostic {
        let signal = latestSignal(agent: agent, source: .hook, in: signals)
        guard let config else {
            return diagnostic(source: .hook, signal: signal, fallback: .notInstalled,
                              now: now, staleAfter: staleAfter)
        }
        let installed = fm.fileExists(atPath: (installMarker ?? config).path)
        guard installed else {
            return diagnostic(source: .hook, signal: signal, fallback: .notInstalled,
                              now: now, staleAfter: staleAfter)
        }
        guard fm.fileExists(atPath: config.path) else {
            return diagnostic(source: .hook, signal: signal, fallback: .eventsMissing,
                              reasonCode: "configurationIncomplete",
                              now: now, staleAfter: staleAfter, forceFallback: true)
        }
        guard let data = readData(at: config, upToCount: 1 << 20, fileManager: fm),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["hooks"] == nil || root["hooks"] is [String: Any] else {
            return diagnostic(source: .hook, signal: signal, fallback: .sourceUnreadable,
                              now: now, staleAfter: staleAfter, forceFallback: true)
        }

        let hooks = root["hooks"] as? [String: Any] ?? [:]
        var coverage = Set<ObservationEventCoverage>()
        var hasManagedHook = false
        var hasAsyncManagedHook = false
        for (event, groups) in hooks {
            guard let groups = groups as? [[String: Any]] else { continue }
            for group in groups {
                guard let commands = group["hooks"] as? [[String: Any]] else { continue }
                for command in commands {
                    guard let value = command["command"] as? String,
                          isManagedHook(command, value: value, agent: agent, event: event)
                    else { continue }
                    hasManagedHook = true
                    if command["async"] as? Bool == true { hasAsyncManagedHook = true }
                    if let family = eventFamily(event) { coverage.insert(family) }
                }
            }
        }
        let configurationIncomplete = !hasManagedHook
            || !requiredHookCoverage.isSubset(of: coverage)
        // Codex runs `async` hooks detached and drops their output, so an async
        // managed hook is a configuration error rather than a missing event.
        let fallback: ObservationHealth =
            (agent == .codex && hasAsyncManagedHook) ? .asyncIncompatible
                : configurationIncomplete ? .eventsMissing : .temporarilySilent
        return diagnostic(source: .hook, signal: signal, fallback: fallback,
                          reasonCode: fallback == .asyncIncompatible ? nil
                            : configurationIncomplete ? "configurationIncomplete" : "awaitingActivity",
                          configuredCoverage: Array(coverage), now: now,
                          staleAfter: staleAfter,
                          forceFallback: fallback == .asyncIncompatible || configurationIncomplete)
    }

    /// Recognize only the installer's executable + agent, never execute inspected
    /// commands. Claude's exec form keeps paths (including spaces) in `command`.
    private static func isManagedHook(
        _ hook: [String: Any], value: String, agent: AgentKind, event: String
    ) -> Bool {
        guard hook["type"] == nil || hook["type"] as? String == "command" else { return false }
        let argv: [String]
        if let args = hook["args"] {
            guard let args = args as? [String] else { return false }
            argv = [value] + args
        } else {
            guard let words = literalShellWords(value) else { return false }
            argv = words
        }
        guard let executable = argv.first, executable.hasPrefix("/") else { return false }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let expected: String
        switch agent {
        case .claudeCode: expected = "claude"
        case .codex: expected = "codex"
        case .grok: expected = "grok"
        default: return false
        }
        if name == "vibebuddy-forward.sh" { return argv.count == 2 && argv[1] == expected }
        guard name == "approval-hook.sh" else { return false }
        if agent == .claudeCode {
            return (argv.count == 1 || argv == [executable, expected])
                && ["PermissionRequest", "PreToolUse"].contains(event)
        }
        return argv == [executable, expected]
            && event == (agent == .codex ? "PermissionRequest" : "PreToolUse")
    }

    /// A deliberately bounded literal shell grammar: quotes and escaped paths,
    /// no operators, expansion, comments, substitutions or command wrappers.
    private static func literalShellWords(_ command: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for c in command {
            if escaped {
                guard c != "\n", c != "\r" else { return nil }
                // Inside double quotes a backslash only escapes shell-special
                // characters; keep it before ordinary path characters.
                if quote == "\"", !"$`\"\\".contains(c) { word.append("\\") }
                word.append(c); escaped = false; started = true; continue
            }
            if c == "\\", quote != "'" { escaped = true; started = true; continue }
            if let q = quote {
                if c == q { quote = nil }
                else {
                    if q == "\"", c == "$" || c == "`" { return nil }
                    word.append(c)
                }
                continue
            }
            if c == "'" || c == "\"" { quote = c; started = true }
            else if c == "\n" || c == "\r" { return nil }
            else if c == " " || c == "\t" {
                if started { words.append(word); word = ""; started = false }
            } else {
                guard !";|&<>()$`#*?[]{}~".contains(c) else { return nil }
                word.append(c); started = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if started { words.append(word) }
        return words
    }

    private static func passiveEvidence(
        root: URL?,
        source: ObservationSource,
        agent: AgentKind,
        installed: Bool?,
        signals: [ObservationRuntimeSignal],
        now: Date,
        staleAfter: TimeInterval,
        fileManager fm: FileManager
    ) -> ObservationSourceDiagnostic {
        let signal = latestSignal(agent: agent, source: source, in: signals)
        if source != .rollout, let signal, signal.health == .unknownVersion {
            return diagnostic(source: source, signal: signal, fallback: .unknownVersion,
                              now: now, staleAfter: staleAfter, forceFallback: true)
        }
        guard installed != false else {
            return diagnostic(source: source, signal: signal, fallback: .notInstalled,
                              now: now, staleAfter: staleAfter)
        }
        guard let root else {
            return diagnostic(source: source, signal: signal, fallback: .eventsMissing,
                              now: now, staleAfter: staleAfter)
        }

        // Claude transcript paths arrive on hooks and are tracked as runtime
        // signals. Do not recursively walk every historical project transcript
        // during a Settings refresh. Codex diagnostics inspect current rollouts
        // plus the latest stale file so a restart retains freshness evidence.
        guard source == .rollout else {
            return diagnostic(source: source, signal: signal, fallback: .temporarilySilent,
                              reasonCode: "awaitingActivity",
                              now: now, staleAfter: staleAfter)
        }

        return rolloutEvidence(root: root, signal: signal, now: now,
                               staleAfter: staleAfter, fileManager: fm)
    }

    private static func rolloutEvidence(
        root: URL, signal: ObservationRuntimeSignal?, now: Date,
        staleAfter: TimeInterval, fileManager fm: FileManager
    ) -> ObservationSourceDiagnostic {
        func row(_ health: ObservationHealth, reason: String? = nil,
                 version: String? = nil, observedAt: Date? = nil) -> ObservationSourceDiagnostic {
            ObservationSourceDiagnostic(source: .rollout, health: health,
                lastObservedAt: signal?.lastObservedAt ?? observedAt,
                observedCoverage: signal?.observedCoverage ?? [],
                reasonCode: reason, sourceVersion: version)
        }
        let files: [CodexRolloutDiscovery.Candidate]
        switch CodexRolloutDiscovery.candidates(in: root, now: now, window: nil, fileManager: fm) {
        case .unreadable, .found(_, incomplete: true):
            return row(.sourceUnreadable)
        case .empty:
            if signal?.health == .unknownVersion {
                return row(.unknownVersion, reason: "invalidSourceData")
            }
            return diagnostic(source: .rollout, signal: signal, fallback: .eventsMissing,
                              now: now, staleAfter: staleAfter)
        case .found(let candidates, incomplete: false):
            let ordered = candidates.sorted {
                $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt
            }
            // Check the monitor's current window, plus the latest file after a
            // restart. A newer healthy thread must not hide another current
            // thread's corrupt rollout. Never read all historical bodies.
            files = ordered.enumerated().compactMap { index, file in
                index == 0 || now.timeIntervalSince(file.modifiedAt) <= CodexRolloutDiscovery.recencyWindow
                    ? file : nil
            }
        }
        var readable: (version: String, progress: Bool, modifiedAt: Date)?
        var unverified: String?
        var invalidVersion: String?
        var invalid = false
        for file in files {
            switch inspectRollout(at: file.url, fileManager: fm) {
            case .unreadable: return row(.sourceUnreadable)
            case .invalid(let version):
                if !invalid { invalidVersion = version }
                invalid = true
            case .readable(let version, let progress):
                if readable == nil { readable = (version, progress, file.modifiedAt) }
                if unverified == nil, !isSupportedVersion(version) { unverified = version }
            }
        }
        // Actual file/runtime failures outrank version certification and other
        // fresh signals. These facts never enter the session reducer.
        if signal?.health == .sourceUnreadable { return row(.sourceUnreadable) }
        if invalid || signal?.health == .unknownVersion {
            return row(.unknownVersion, reason: "invalidSourceData",
                       version: invalid ? invalidVersion : readable?.version)
        }
        if let unverified {
            return row(.unknownVersion, reason: "versionUnverified", version: unverified)
        }
        guard let readable else { return row(.eventsMissing) }
        if let signal {
            var result = diagnostic(source: .rollout, signal: signal, fallback: .eventsMissing,
                                    now: now, staleAfter: staleAfter)
            result.sourceVersion = readable.version
            return result
        }
        guard readable.progress else {
            return row(.eventsMissing, version: readable.version)
        }
        return row(now.timeIntervalSince(readable.modifiedAt) > staleAfter ? .temporarilySilent : .healthy,
                   version: readable.version, observedAt: readable.modifiedAt)
    }

    private static func diagnostic(
        source: ObservationSource,
        signal: ObservationRuntimeSignal?,
        fallback: ObservationHealth,
        reasonCode: String? = nil,
        lastObservedAt: Date? = nil,
        configuredCoverage: [ObservationEventCoverage] = [],
        now: Date,
        staleAfter: TimeInterval,
        forceFallback: Bool = false
    ) -> ObservationSourceDiagnostic {
        let health: ObservationHealth
        if forceFallback {
            health = fallback
        } else if let signal {
            if signal.health != .healthy {
                health = signal.health
            } else if now.timeIntervalSince(signal.lastObservedAt) > staleAfter {
                health = .temporarilySilent
            } else {
                health = .healthy
            }
        } else {
            health = fallback
        }
        return ObservationSourceDiagnostic(
            source: source,
            health: health,
            lastObservedAt: signal?.lastObservedAt ?? lastObservedAt,
            configuredCoverage: configuredCoverage,
            observedCoverage: signal?.observedCoverage ?? [],
            reasonCode: (forceFallback || signal == nil) ? reasonCode : nil)
    }

    private static func latestSignal(
        agent: AgentKind,
        source: ObservationSource,
        in signals: [ObservationRuntimeSignal]
    ) -> ObservationRuntimeSignal? {
        signals.filter { $0.agent == agent && $0.source == source }
            .max { $0.lastObservedAt < $1.lastObservedAt }
    }

    /// Config keys are PascalCase across every CLI we install into (grok accepts
    /// the same spelling as Claude), so one table covers them all.
    private static func eventFamily(_ event: String) -> ObservationEventCoverage? {
        switch event {
        case "SessionStart", "SessionEnd", "PostModelSwitch", "CwdChanged",
             "SubagentStart", "SubagentStop": .lifecycle
        case "UserPromptSubmit", "Stop", "StopFailure", "StopCancelled", "Interrupt": .turn
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch": .tool
        case "PermissionRequest", "PermissionDenied", "Notification", "Elicitation": .attention
        default: nil
        }
    }

    private static func isReadable(_ url: URL, fileManager fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: url.path),
              fm.isReadableFile(atPath: url.path),
              let attributes = try? fm.attributesOfItem(atPath: url.path),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o444 != 0
        else { return false }
        return true
    }

    private static func readData(
        at url: URL,
        upToCount count: Int,
        fileManager fm: FileManager
    ) -> Data? {
        guard isReadable(url, fileManager: fm),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }

    private static func inspectRollout(
        at url: URL,
        fileManager fm: FileManager
    ) -> RolloutInspection {
        let limit = 1 << 20
        guard var data = readData(at: url, upToCount: limit, fileManager: fm) else { return .unreadable }
        let fileSize = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
        let truncated = (fileSize ?? data.count) > data.count
        // The cap can bisect JSON or UTF-8; only complete records are evidence.
        if truncated, data.last != 0x0A {
            guard let newline = data.lastIndex(of: 0x0A) else { return .invalid(version: nil) }
            data = data.prefix(through: newline)
        }
        var version: String?
        var hasProgress = false
        var invalid = false
        for line in data.split(separator: 0x0A) {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = record["type"] as? String, !type.isEmpty else {
                invalid = true
                continue
            }
            // New unrelated optional record types are not schema failures.
            guard ["session_meta", "event_msg", "response_item", "turn_context"].contains(type) else { continue }
            guard let payload = record["payload"] as? [String: Any] else {
                invalid = true
                continue
            }
            if type == "session_meta" {
                guard let value = payload["cli_version"] as? String,
                      value.range(of: #"^\d+\.\d+\.\d+(?:-[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?(?:\+[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?$"#,
                                  options: .regularExpression) != nil else {
                    invalid = true
                    continue
                }
                if let version, version != value { invalid = true }
                version = value
                // Without identity the parser discards every lifecycle event.
                if (payload["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    invalid = true
                }
            } else if type == "event_msg" || type == "response_item" {
                guard let event = payload["type"] as? String, !event.isEmpty else {
                    invalid = true
                    continue
                }
                if let turnID = payload["turn_id"], !(turnID is String), !(turnID is NSNull) {
                    invalid = true
                }
                if type == "event_msg", event == "item_completed" {
                    guard let item = payload["item"] as? [String: Any],
                          let itemType = item["type"] as? String, !itemType.isEmpty else {
                        invalid = true
                        continue
                    }
                    // Unknown optional items cannot prove progress on their own.
                    hasProgress = hasProgress || ["CommandExecution", "McpToolCall", "FileChange",
                        "Extension", "ContextCompaction", "FunctionCallOutput", "CollabAgentToolCall",
                        "ImageView"].contains(itemType)
                } else {
                    hasProgress = hasProgress || (type == "event_msg"
                        ? supportedEventMessages.contains(event)
                        : supportedResponseItems.contains(event)
                            || (event == "message" && payload["phase"] as? String == "final_answer"))
                }
            }
        }
        guard !invalid, let version else { return .invalid(version: version) }
        return .readable(version: version, hasProgress: hasProgress)
    }

    private static func isSupportedVersion(_ version: String) -> Bool {
        guard version.range(of: #"^\d+\.\d+\.\d+(?:[-+].*)?$"#,
                            options: .regularExpression) != nil,
              let major = version.split(separator: ".").first.flatMap({ Int($0) }) else { return false }
        let components = version.split(separator: ".")
        guard components.count >= 2, let minor = Int(components[1]) else { return false }
        // Pre-1.0 minor versions may change the rollout schema. Keep this an
        // explicit allowlist so a future semver is not mistaken for evidence.
        // H2-R real Desktop replay verified 0.153.3 turn/tool/model/token shapes.
        // Admit only that observed release, not every unverified 0.153 patch.
        return (major == 0 && minor == 151) || version == "0.153.3"
    }
}
