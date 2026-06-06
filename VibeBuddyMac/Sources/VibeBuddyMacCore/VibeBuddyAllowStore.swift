import Foundation

/// Derives and matches vibebuddy's own "always allow" rules. See ADR 0010.
///
/// Rules are persisted in `PermissionMatcher`'s `Tool(arg)` grammar, but matched
/// **exactly** (no glob, no composition guard) — the user approved this precise tool
/// use, so the matcher's conservative heuristics for *pattern* rules don't apply.
public enum AllowRule {
    /// The conservative rule to persist when the user picks "Always allow":
    /// Bash → the exact command, file tools → the target path, else the bare tool.
    public static func forApproval(tool: String, input: [String: Any]) -> String? {
        switch tool {
        case "Bash":
            let cmd = ((input["command"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cmd.isEmpty ? nil : "Bash(\(cmd))"
        case "Read", "Write", "Edit", "MultiEdit":
            let path = (input["file_path"] as? String) ?? ""
            return path.isEmpty ? nil : "\(tool)(\(path))"
        default:
            return tool.isEmpty ? nil : tool
        }
    }

    /// True when `rule` names this precise tool use (exact equality).
    static func matchesExactly(_ rule: String, tool: String, input: [String: Any]) -> Bool {
        let p = PermissionMatcher.parseRule(rule)
        guard p.tool == tool else { return false }
        guard let arg = p.arg else { return true }   // bare tool rule
        switch tool {
        case "Bash":
            let cmd = ((input["command"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cmd == arg
        case "Read", "Write", "Edit", "MultiEdit":
            return ((input["file_path"] as? String) ?? "") == arg
        default:
            return false
        }
    }
}

/// vibebuddy's own persisted "always allow" list, evaluated by the daemon's
/// `/approval` path *in addition to* the native Claude allow/deny it reads from
/// `settings.json` — never replacing it (ADR 0010). Reversible: delete the file
/// or clear it from the UI.
public actor VibeBuddyAllowStore {
    private let url: URL
    private var rules: [String]

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("vibebuddy/permission-allow.json")
    }

    public init(url: URL = defaultURL()) {
        self.url = url
        self.rules = Self.read(url)
    }

    public func all() -> [String] { rules }

    /// Persist a rule. No-op if empty or already present. Returns whether it was added.
    @discardableResult
    public func add(_ rule: String) -> Bool {
        guard !rule.isEmpty, !rules.contains(rule) else { return false }
        rules.append(rule)
        write()
        return true
    }

    public func clear() {
        rules = []
        write()
    }

    private static func read(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["allow"] as? [String] else { return [] }
        return arr
    }

    private func write() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(
            withJSONObject: ["allow": rules], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Sessions the user chose to "allow all for this session". In-memory only —
/// cleared when the daemon restarts; never persisted (ADR 0010).
public actor SessionAllowList {
    private var ids: Set<String> = []
    public init() {}
    public func contains(_ id: String) -> Bool { ids.contains(id) }
    public func add(_ id: String) { ids.insert(id) }
    public func remove(_ id: String) { ids.remove(id) }
}

/// Maps a held approval id to the context `/decision` needs to act on an
/// "always allow" / "allow this session": the session it belongs to and the
/// candidate rule to persist. Registered when an approval starts holding,
/// consumed when the phone decides.
public actor ApprovalContextStore {
    public struct Context: Sendable { public let sessionID: String; public let rule: String? }
    private var contexts: [String: Context] = [:]
    public init() {}
    public func set(id: String, sessionID: String, rule: String?) {
        contexts[id] = Context(sessionID: sessionID, rule: rule)
    }
    public func take(id: String) -> Context? { contexts.removeValue(forKey: id) }
}
