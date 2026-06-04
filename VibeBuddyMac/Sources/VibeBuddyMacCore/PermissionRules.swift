import Foundation

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
}
