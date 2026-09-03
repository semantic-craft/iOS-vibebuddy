import Foundation
import VibeBuddyKit

/// The allow/deny lists vibebuddy uses to decide silent-vs-ask. Read from the
/// user-level Claude Code settings; project-level merging is out of scope (its
/// absence only causes safe over-asking).
public struct PermissionRules: Sendable {
    public let allow: [String]
    public let deny: [String]

    public init(allow: [String], deny: [String]) {
        self.allow = allow
        self.deny = deny
    }

    public static func defaultSettingsURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    public static func load(settingsURL: URL = defaultSettingsURL()) -> PermissionRules {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let perms = obj["permissions"] as? [String: Any]
        else { return PermissionRules(allow: [], deny: []) }
        let allow = (perms["allow"] as? [String]) ?? []
        let deny = (perms["deny"] as? [String]) ?? []
        return PermissionRules(allow: allow, deny: deny)
    }

    /// The rules that agent actually honours. Grok Build reads its own
    /// `~/.grok/config.toml` `[permission]` lists *and* `~/.claude/settings.json`,
    /// so vibebuddy's gate merges the same two sources — anything less and the
    /// phone would be asked about calls Grok runs silently. Every other agent
    /// reads the Claude settings only.
    public static func load(for agent: AgentKind) -> PermissionRules {
        let claude = load()
        guard agent == .grok else { return claude }
        let grok = GrokPermissionConfig.load()
        return PermissionRules(allow: claude.allow + grok.allow,
                               deny: claude.deny + grok.deny)
    }
}
