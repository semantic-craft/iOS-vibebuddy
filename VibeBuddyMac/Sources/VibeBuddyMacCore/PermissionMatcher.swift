import Foundation

/// What to do with a tool use, derived purely from the permission rules.
public enum PermissionDecision: String, Sendable {
    case allow, deny, ask
}

/// Conservative replica of *just enough* of Claude Code's permission matching to
/// decide "silent vs ask": deny-list → .deny, allow-list → .allow, else .ask.
/// When unsure it returns .ask (over-asking is safe; under-asking is not).
public enum PermissionMatcher {

    /// Shell metacharacters that compose/redirect/background a command. A Bash
    /// command containing any of these is never auto-allowed.
    private static let composition: [String] = ["&&", "||", "|", ";", "$(", "`", ">", "<", "&", "\n"]

    public static func decide(
        tool: String, input: [String: Any], allow: [String], deny: [String]
    ) -> PermissionDecision {
        if deny.contains(where: { ruleMatches($0, tool: tool, input: input) }) { return .deny }
        if tool == "Bash", containsComposition(bashCommand(input)) { return .ask }
        if allow.contains(where: { ruleMatches($0, tool: tool, input: input) }) { return .allow }
        return .ask
    }

    static func containsComposition(_ command: String) -> Bool {
        composition.contains { command.contains($0) }
    }

    private static func bashCommand(_ input: [String: Any]) -> String {
        (input["command"] as? String) ?? ""
    }

    private static func filePath(_ input: [String: Any]) -> String {
        (input["file_path"] as? String) ?? ""
    }

    /// Parse `Tool(arg)` → (tool, arg); `Tool` → (tool, nil).
    static func parseRule(_ rule: String) -> (tool: String, arg: String?) {
        guard let open = rule.firstIndex(of: "("), rule.hasSuffix(")") else {
            return (rule, nil)
        }
        let tool = String(rule[rule.startIndex..<open])
        let arg = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
        return (tool, arg)
    }

    private static func ruleMatches(_ rule: String, tool: String, input: [String: Any]) -> Bool {
        let parsed = parseRule(rule)
        guard parsed.tool == tool else { return false }
        guard let arg = parsed.arg else { return true }   // bare tool rule

        switch tool {
        case "Bash":
            let cmd = bashCommand(input).trimmingCharacters(in: .whitespaces)
            if arg.hasSuffix(":*") {
                let prefix = String(arg.dropLast(2))
                return cmd == prefix || cmd.hasPrefix(prefix + " ")
            }
            return cmd == arg
        case "Read", "Write", "Edit", "MultiEdit":
            return globMatches(arg, filePath(input))
        default:
            return false   // unknown tool with an arg pattern → conservative miss → .ask
        }
    }

    /// gitignore-ish glob: a leading `//` means absolute root, `**` matches any
    /// run (incl. `/`), `*` matches within a path segment.
    static func globMatches(_ pattern: String, _ path: String) -> Bool {
        var pat = pattern
        if pat.hasPrefix("//") { pat = String(pat.dropFirst()) }   // //abs → /abs
        let regex = "^" + pat
            .replacingOccurrences(of: "**", with: "\u{1}")          // placeholder
            .replacingOccurrences(of: "*", with: "[^/]*")
            .replacingOccurrences(of: "\u{1}", with: ".*") + "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
