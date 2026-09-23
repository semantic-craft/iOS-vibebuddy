import Foundation

extension CodexHookTrust {
    /// The script basenames vibebuddy writes into Codex's `hooks.json`. A hook
    /// naming one of these is ours; every other hook is none of our business.
    static let markers = ["vibebuddy-forward.sh", "approval-hook.sh", "capture-terminal.sh"]
    /// `HookTrustStatus` values that let Codex run a hook. `modified` (edited
    /// since it was trusted) and `untrusted` (never trusted) are skipped
    /// silently — writing hooks.json does not make a hook run.
    static let running: Set<String> = ["trusted", "managed"]

    /// Our hooks in a `hooks/list` result, once each (the daemon reports a
    /// definition once per working directory it applies to). Nil when the
    /// daemon knows none of ours.
    init?(hooksList result: [String: Any]) {
        var seen: Set<String> = []
        var installed = 0
        var blocked = 0
        var blockedEvents: Set<String> = []
        for entry in result["data"] as? [[String: Any]] ?? [] {
            for hook in entry["hooks"] as? [[String: Any]] ?? [] {
                guard let command = hook["command"] as? String,
                      Self.markers.contains(where: command.contains) else { continue }
                let key = (hook["key"] as? String) ?? command
                guard seen.insert(key).inserted else { continue }
                installed += 1
                let trusted = Self.running.contains((hook["trustStatus"] as? String) ?? "")
                guard hook["enabled"] as? Bool == false || !trusted else { continue }
                blocked += 1
                if let event = hook["eventName"] as? String { blockedEvents.insert(event) }
            }
        }
        guard installed > 0 else { return nil }
        self.init(installed: installed, blockedEvents: blockedEvents.sorted(), blocked: blocked)
    }
}

/// Asks the running Codex app-server whether it will actually run
/// vibebuddy's hooks — the Swift port of the retired `codex_hook_trust.py`.
/// Read-only: `initialize` and `hooks/list`, then close. It never writes a
/// trusted hash; trusting a hook is the user's decision, made in `/hooks`.
public enum CodexHookTrustProbe {
    public enum Verdict: Equatable, Sendable {
        case ok(CodexHookTrust)
        /// Codex knows none of our hooks, or is skipping some.
        case blocked(CodexHookTrust?)
        /// No daemon answered: no verdict, not a failure.
        case unreachable(String)
    }

    public static func check(
        socketPath: String = CodexAppServerClient.defaultSocketPath,
        timeout: Duration = .seconds(5),
        makeClient: @Sendable (String) -> any CodexAppServerConnecting = { CodexAppServerClient(socketPath: $0) }
    ) async -> Verdict {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return .unreachable("\(socketPath): no such socket")
        }
        let client = makeClient(socketPath)
        defer { client.close() }
        do {
            try client.connect()
            _ = try await client.request("initialize", params: [
                "clientInfo": ["name": "vibebuddy-hook-trust", "version": "1"]], timeout: timeout)
            client.notify("initialized")
            let result = try await client.request("hooks/list", params: [:], timeout: timeout)
            guard let trust = CodexHookTrust(hooksList: result) else { return .blocked(nil) }
            return trust.blocked == 0 ? .ok(trust) : .blocked(trust)
        } catch {
            return .unreachable("\(error)")
        }
    }

    /// Human-readable lines for install output and `vibebuddyd hooks status`.
    public static func lines(for verdict: Verdict) -> [String] {
        switch verdict {
        case .ok(let trust):
            return ["Codex is running all \(trust.installed) VibeBuddy hooks."]
        case .blocked(nil):
            return ["Codex reports no VibeBuddy hooks at all.",
                    "Install the hooks, then start a fresh Codex session."]
        case .blocked(let trust?):
            return ["Codex is skipping \(trust.blocked) of \(trust.installed) VibeBuddy hooks "
                        + "(\(trust.blockedEvents.joined(separator: ", "))); it does not report this as an error.",
                    "A hook Codex has not trusted since its last change never runs.",
                    "Fix: start a fresh Codex session, run /hooks, and trust the VibeBuddy entries."]
        case .unreachable(let reason):
            return ["could not ask Codex whether its hooks are trusted (\(reason)).",
                    "Start Codex, then check again."]
        }
    }
}
