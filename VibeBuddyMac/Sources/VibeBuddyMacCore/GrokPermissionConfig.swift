import Foundation

/// The `[permission]` allow / deny lists Grok Build reads from its own
/// `~/.grok/config.toml`, in the same Claude-style rule grammar
/// (`Bash(npm *)`, `Read(/x/**)`).
///
/// Grok honours these *alongside* `~/.claude/settings.json`, so vibebuddy's
/// approval gate has to see both — otherwise it would hold the phone on calls
/// Grok itself would have run silently, or (worse) auto-allow one the user
/// denied natively.
///
/// Deliberately a small scanner rather than a new dependency: we need exactly
/// one table and two arrays of strings out of the file, and the package has no
/// TOML library.
///
/// Unsupported grammar, all of it deliberately: multi-line basic (`"""`) and
/// literal (`'''`) strings, `[permission.…]` sub-tables, the structured
/// `[[permission.rules]]` form, and dotted/quoted keys. Every one of them yields
/// *fewer* rules than the file states, so the failure direction is over-asking
/// (the phone is asked about a call Grok would have run silently) and never
/// auto-allowing something the user did not allow.
public enum GrokPermissionConfig {

    /// `<grok home>/config.toml`.
    public static func defaultConfigURL() -> URL {
        GrokHome.url.appendingPathComponent("config.toml")
    }

    public static func load(configURL: URL = defaultConfigURL()) -> PermissionRules {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return PermissionRules(allow: [], deny: [])
        }
        return parse(text)
    }

    static func parse(_ text: String) -> PermissionRules {
        var section = ""
        var collecting: (key: String, body: String, depth: Int)?
        var lists: [String: [String]] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine))

            if var open = collecting {
                open.body += "\n" + line
                open.depth += bracketDelta(line)
                if open.depth <= 0 {
                    lists[open.key] = stringLiterals(open.body)
                    collecting = nil
                } else {
                    collecting = open
                }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                section = sectionName(trimmed)
                continue
            }
            guard section == "permission",
                  let (key, value) = keyValue(trimmed),
                  key == "allow" || key == "deny",
                  value.hasPrefix("[")
            else { continue }

            let depth = bracketDelta(value)
            if depth <= 0 {
                lists[key] = stringLiterals(value)
            } else {
                collecting = (key, value, depth)
            }
        }

        return PermissionRules(allow: lists["allow"] ?? [], deny: lists["deny"] ?? [])
    }

    // MARK: - scanning primitives

    /// `[permission]` / `[[permission.rules]]` → `permission` / `permission.rules`.
    private static func sectionName(_ line: String) -> String {
        var name = line.drop(while: { $0 == "[" })
        if let close = name.firstIndex(where: { $0 == "]" }) { name = name[name.startIndex..<close] }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Split `key = value` on the first `=` outside a string. Bare keys only —
    /// quoted/dotted keys never name `allow`/`deny` at the top of `[permission]`.
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    /// Drop a `#` comment, respecting quoted strings.
    private static func stripComment(_ line: String) -> String {
        var out = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if let q = quote {
                out.append(ch)
                if escaped { escaped = false }
                else if q == "\"" && ch == "\\" { escaped = true }
                else if ch == q { quote = nil }
                continue
            }
            if ch == "#" { break }
            if ch == "\"" || ch == "'" { quote = ch }
            out.append(ch)
        }
        return out
    }

    /// Net `[` minus `]` outside strings — how much of the array is still open.
    private static func bracketDelta(_ text: String) -> Int {
        var depth = 0
        var quote: Character?
        var escaped = false
        for ch in text {
            if let q = quote {
                if escaped { escaped = false }
                else if q == "\"" && ch == "\\" { escaped = true }
                else if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch
            case "[": depth += 1
            case "]": depth -= 1
            default: break
            }
        }
        return depth
    }

    /// Every quoted string in an array body, in order. Basic strings honour the
    /// escapes a rule can realistically contain (`\"`, `\\`); literal `'…'`
    /// strings are taken verbatim, as TOML defines them.
    private static func stringLiterals(_ text: String) -> [String] {
        var out: [String] = []
        var current: String?
        var quote: Character?
        var escaped = false
        for ch in text {
            guard let q = quote else {
                if ch == "\"" || ch == "'" { quote = ch; current = "" }
                continue
            }
            if escaped {
                current?.append(unescape(ch))
                escaped = false
            } else if q == "\"" && ch == "\\" {
                escaped = true
            } else if ch == q {
                out.append(current ?? "")
                current = nil
                quote = nil
            } else {
                current?.append(ch)
            }
        }
        return out
    }

    private static func unescape(_ ch: Character) -> Character {
        switch ch {
        case "n": return "\n"
        case "t": return "\t"
        default: return ch      // \" \\ \/ and anything else: the character itself
        }
    }
}
