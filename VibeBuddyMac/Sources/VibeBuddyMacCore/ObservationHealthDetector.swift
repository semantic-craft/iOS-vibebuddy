import Foundation
import VibeBuddyKit

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
        case supportedEvent
        case metadataOnly
        case unsupported
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
                              now: now, staleAfter: staleAfter)
        }
        guard let data = readData(at: config, upToCount: 1 << 20, fileManager: fm),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return diagnostic(source: .hook, signal: signal, fallback: .sourceUnreadable,
                              now: now, staleAfter: staleAfter)
        }

        var coverage = Set<ObservationEventCoverage>()
        var hasManagedHook = false
        var hasAsyncManagedHook = false
        for (event, groups) in hooks {
            guard let groups = groups as? [[String: Any]] else { continue }
            for group in groups {
                guard let commands = group["hooks"] as? [[String: Any]] else { continue }
                for command in commands {
                    guard let value = command["command"] as? String,
                          value.contains("vibebuddy-forward.sh") || value.contains("127.0.0.1:9876/hook")
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
            (agent == .codex && hasAsyncManagedHook) ? .asyncIncompatible : .eventsMissing
        return diagnostic(source: .hook, signal: signal, fallback: fallback,
                          configuredCoverage: Array(coverage), now: now,
                          staleAfter: staleAfter,
                          forceFallback: fallback == .asyncIncompatible || configurationIncomplete)
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
        if let signal, signal.health == .unknownVersion {
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
        // during a Settings refresh. Codex diagnostics take the newest rollout
        // by mtime, including files outside the monitor recency window, so a
        // restart still has freshness evidence.
        guard source == .rollout else {
            return diagnostic(source: source, signal: signal, fallback: .eventsMissing,
                              now: now, staleAfter: staleAfter)
        }

        switch CodexRolloutDiscovery.latest(in: root, now: now, fileManager: fm) {
        case .unreadable:
            return diagnostic(source: source, signal: signal, fallback: .sourceUnreadable,
                              now: now, staleAfter: staleAfter, forceFallback: true)
        case .empty:
            return diagnostic(source: source, signal: signal, fallback: .eventsMissing,
                              now: now, staleAfter: staleAfter)
        case .found(let url, let modifiedAt):
            guard isReadable(url, fileManager: fm) else {
                return diagnostic(source: source, signal: signal, fallback: .sourceUnreadable,
                                  now: now, staleAfter: staleAfter, forceFallback: true)
            }
            switch inspectRollout(at: url, fileManager: fm) {
            case .unsupported:
                return diagnostic(source: source, signal: signal, fallback: .unknownVersion,
                                  lastObservedAt: modifiedAt,
                                  now: now, staleAfter: staleAfter, forceFallback: true)
            case .metadataOnly:
                return diagnostic(source: source, signal: signal, fallback: .eventsMissing,
                                  lastObservedAt: modifiedAt,
                                  now: now, staleAfter: staleAfter)
            case .supportedEvent:
                if let signal {
                    return diagnostic(source: source, signal: signal, fallback: .eventsMissing,
                                      now: now, staleAfter: staleAfter)
                }
            }
            let inferred = ObservationRuntimeSignal(
                agent: agent, source: source, lastObservedAt: modifiedAt)
            return diagnostic(source: source, signal: inferred, fallback: .eventsMissing,
                              now: now, staleAfter: staleAfter)
        }
    }

    private static func diagnostic(
        source: ObservationSource,
        signal: ObservationRuntimeSignal?,
        fallback: ObservationHealth,
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
            observedCoverage: signal?.observedCoverage ?? [])
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
        guard var data = readData(at: url, upToCount: limit, fileManager: fm) else { return .unsupported }
        let fileSize = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
        let truncated = (fileSize ?? data.count) > data.count
        // The byte limit can split a UTF-8 character as well as a JSON record.
        // Drop the incomplete record before strict decoding, so a valid stream
        // is not rejected merely because its 1 MiB boundary falls inside text.
        if truncated, data.last != 0x0A {
            guard let newline = data.lastIndex(of: 0x0A) else { return .unsupported }
            data = data.prefix(through: newline)
        }
        guard let text = String(data: data, encoding: .utf8) else { return .unsupported }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        var version: String?
        var hasSupportedEvent = false
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let type = record["type"] as? String else { return .unsupported }
            if type == "session_meta" {
                guard let payload = record["payload"] as? [String: Any],
                      let value = payload["cli_version"] as? String else { return .unsupported }
                version = value
            } else if type == "event_msg" {
                guard let payload = record["payload"] as? [String: Any],
                      let event = payload["type"] as? String else { return .unsupported }
                hasSupportedEvent = hasSupportedEvent || supportedEventMessages.contains(event)
            } else if type == "response_item" {
                guard let payload = record["payload"] as? [String: Any],
                      let item = payload["type"] as? String else { return .unsupported }
                hasSupportedEvent = hasSupportedEvent
                    || supportedResponseItems.contains(item)
                    || (item == "message" && payload["phase"] as? String == "final_answer")
            }
        }
        guard let version, isSupportedVersion(version) else { return .unsupported }
        return hasSupportedEvent ? .supportedEvent : .metadataOnly
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
