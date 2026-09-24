import Foundation

/// Grok Build's status line, `[ui.status_line]` in `<grok home>/config.toml`,
/// wrapped the way Claude's `statusLine` is: the table becomes
/// `type = "command"` naming `vibebuddy-statusline.sh grok <key>`, and the
/// user's own command (if any) is saved beside the token for the wrapper to
/// run. Grok reads the table only at startup, so a change applies to the next
/// session.
///
/// The config is the user's hand-written TOML, so it is edited as text and
/// only inside that one table: every other line keeps its bytes, comments and
/// order. A status line written any other way — an inline `ui = {…}` or
/// `status_line = {…}`, dotted `status_line.type` keys, a multi-line string —
/// is left alone with a note rather than risk a file Grok cannot read. A
/// `builtin` row is kept too: a command cannot reproduce it.
struct GrokStatusLine {
    let paths: HookPaths
    var files: HookFileStore { HookFileStore(paths: paths) }

    static let marker = "vibebuddy-statusline.sh"

    var command: String {
        ShellWords.quoted(paths.script(Self.marker).path) + " grok " + paths.grokKey
    }

    /// What the saved original says was there before vibebuddy: the table's
    /// exact text, or nil when there was no table; and whether config.toml
    /// existed at all, so an uninstall removes a file only vibebuddy made.
    struct Saved: Codable, Equatable {
        var section: String?
        var fileExisted: Bool?
        /// What appending the table added around it, so removing it puts the
        /// file back byte for byte.
        var addedBlankLine: Bool?
        var addedFinalNewline: Bool?
    }

    func isWired() -> Bool {
        guard let text = read(), case .table(let range) = GrokTOMLText(text).locate() else { return false }
        return GrokTOMLText(text).value(of: "command", in: range)?.contains(Self.marker) == true
    }

    func ourCommand() -> String? {
        guard let text = read(), case .table(let range) = GrokTOMLText(text).locate(),
              let command = GrokTOMLText(text).value(of: "command", in: range),
              command.contains(Self.marker) else { return nil }
        return command
    }

    private func read() -> String? { files.read(paths.grokConfig).map { String(decoding: $0, as: UTF8.self) } }

    /// Wrap the configured status line, or add ours. Returns whether the file
    /// changed; `lines` gets a note when the table is left alone.
    func install(lines: inout [String]) throws -> Bool {
        let existing = read()
        let original = existing ?? ""
        var toml = GrokTOMLText(original)
        let range: Range<Int>?
        switch toml.locate() {
        case .foreign(let why):
            lines.append("status line left alone: \(why) in \(paths.grokConfig.path); vibebuddy only edits a [ui.status_line] table.")
            return false
        case .absent: range = nil
        case .table(let found): range = found
        }
        if let range {
            if let type = toml.value(of: "type", in: range), GrokTOMLText.normalizedType(type) == "builtin" {
                lines.append("status line left alone: Grok's built-in row is configured and a command cannot reproduce it.")
                return false
            }
            if toml.hasMultilineValue(in: range) {
                lines.append("status line left alone: [ui.status_line] holds a multi-line value vibebuddy does not edit.")
                return false
            }
            if let current = toml.value(of: "command", in: range), current.contains(Self.marker) {
                // Already ours: keep the saved original, refresh the path.
                guard current != command else { return false }
                toml.set("command", to: command, in: range)
                return try write(toml.text, original: original)
            }
            try saveOriginal(Saved(section: toml.section(range), fileExisted: true),
                             command: GrokTOMLText.normalizedType(toml.value(of: "type", in: range)) == "command"
                                ? toml.value(of: "command", in: range) : nil)
            var updated = range
            updated = toml.set("type", to: "command", in: updated)
            toml.set("command", to: command, in: updated)
        } else {
            let added = toml.appendTable(["type = \"command\"", "command = " + GrokTOMLText.literal(command)])
            try saveOriginal(Saved(section: nil, fileExisted: existing != nil, addedBlankLine: added.blankLine,
                                   addedFinalNewline: added.finalNewline), command: nil)
        }
        return try write(toml.text, original: original)
    }

    /// Put back what was there before. Returns whether the file changed.
    func uninstall(lines: inout [String]) throws -> Bool {
        guard let original = read() else { return false }
        var toml = GrokTOMLText(original)
        guard case .table(let range) = toml.locate(),
              toml.value(of: "command", in: range)?.contains(Self.marker) == true else { return false }
        var removeFile = false
        if let data = files.read(paths.grokStatusLineOriginal),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            if let section = saved.section {
                toml.replace(range, with: section)
            } else {
                toml.removeTable(range, addedBlankLine: saved.addedBlankLine ?? true,
                                 addedFinalNewline: saved.addedFinalNewline ?? false)
                removeFile = saved.fileExisted == false
                    && toml.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        } else {
            // No record of what was there: switch the row off rather than
            // guess, keeping any other keys the user set.
            lines.append("no saved Grok status line was found; [ui.status_line] is set to disabled.")
            let updated = toml.set("type", to: "disabled", in: range)
            toml.remove("command", in: updated)
        }
        let changed: Bool
        if removeFile {
            _ = try files.remove(paths.grokConfig, agent: .grok)
            changed = true
        } else {
            changed = try write(toml.text, original: original)
        }
        for url in [paths.grokStatusLineOriginal, paths.grokStatusLineOriginalCommand] {
            try? FileManager.default.removeItem(at: url)
        }
        return changed
    }

    private func saveOriginal(_ original: Saved, command: String?) throws {
        let data = try JSONEncoder().encode(original)
        try HookFileStore.atomicWrite(data, to: paths.grokStatusLineOriginal, permissions: 0o600)
        var saved = command ?? ""
        if saved.contains(Self.marker) { saved = "" }
        try HookFileStore.atomicWrite(Data(saved.utf8), to: paths.grokStatusLineOriginalCommand, permissions: 0o600)
    }

    private func write(_ text: String, original: String) throws -> Bool {
        guard text != original else { return false }
        _ = try files.write(Data(text.utf8), to: paths.grokConfig, agent: .grok, permissions: 0o644)
        return true
    }
}

/// Line-level view of a TOML document, just enough to find and edit one
/// table without reformatting the rest.
struct GrokTOMLText {
    private(set) var lines: [String]
    private var trailingNewline: Bool

    init(_ text: String) {
        trailingNewline = text.isEmpty || text.hasSuffix("\n")
        var split = text.components(separatedBy: "\n")
        if trailingNewline { split.removeLast() }
        lines = split
    }

    var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + (trailingNewline ? "\n" : "") }

    enum Location: Equatable { case absent, table(Range<Int>), foreign(String) }

    /// Where `[ui.status_line]` is. Lines inside multi-line strings are never
    /// read as headers or keys.
    func locate() -> Location {
        // A line-level edit of a CRLF file would mix line endings; leave it.
        if lines.contains(where: { $0.contains("\r") }) { return .foreign("the file uses CRLF line endings") }
        var table: [String] = []
        var start: Int?
        var end: Int?
        var inMultiline: String?
        for (index, raw) in lines.enumerated() {
            if let delimiter = inMultiline {
                if Self.closing(delimiter, in: Array(raw), from: 0) != nil { inMultiline = nil }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            inMultiline = Self.openMultiline(line)
            if line.hasPrefix("[") {
                if start != nil, end == nil { end = index }
                guard let name = Self.headerName(line) else { continue }
                table = name
                if name == ["ui", "status_line"] {
                    if line.hasPrefix("[[") { return .foreign("[[ui.status_line]] is an array of tables") }
                    if start != nil { return .foreign("[ui.status_line] appears twice") }
                    start = index
                } else if name.count > 2, Array(name.prefix(2)) == ["ui", "status_line"] {
                    return .foreign("a [\(name.joined(separator: "."))] table is set")
                }
                continue
            }
            guard let key = Self.keyPath(line) else { continue }
            let full = table + key
            if full.count >= 2, Array(full.prefix(2)) == ["ui", "status_line"], start == nil || table != ["ui", "status_line"] {
                return .foreign("the status line is set as a key rather than a table")
            }
            if full == ["ui"] { return .foreign("ui is an inline table") }
            if table == ["ui", "status_line"], key.count > 1 {
                return .foreign("[ui.status_line] uses dotted keys")
            }
        }
        guard let start else {
            // Backstop: never add a second table beside one this scan missed.
            if lines.contains(where: Self.namesStatusLineTable) {
                return .foreign("a [ui.status_line] header vibebuddy could not place")
            }
            return .absent
        }
        return .table(start ..< (end ?? lines.count))
    }

    /// `[ui.status_line]` in any spacing or quoting, wherever it appears.
    static func namesStatusLineTable(_ line: String) -> Bool {
        let bare = line.filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
        return bare.hasPrefix("[ui.status_line]") || bare.hasPrefix("[[ui.status_line]]")
    }

    /// The multi-line string delimiter a line leaves open, reading past
    /// single-line strings and a trailing comment.
    static func openMultiline(_ line: String) -> String? {
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "#" { return nil }
            guard c == "\"" || c == "'" else { index += 1; continue }
            if index + 2 < chars.count, chars[index + 1] == c, chars[index + 2] == c {
                let delimiter = String(repeating: c, count: 3)
                guard let close = closing(delimiter, in: chars, from: index + 3) else { return delimiter }
                index = close + 3
                continue
            }
            var next = index + 1
            while next < chars.count, chars[next] != c {
                next += c == "\"" && chars[next] == "\\" ? 2 : 1
            }
            index = next + 1
        }
        return nil
    }

    /// Where `delimiter` next occurs in `chars` from `start`, skipping
    /// escapes inside a basic string.
    static func closing(_ delimiter: String, in chars: [Character], from start: Int) -> Int? {
        let quote = delimiter.first ?? "\""
        var index = start
        while index + 2 < chars.count {
            if quote == "\"", chars[index] == "\\" { index += 2; continue }
            if chars[index] == quote, chars[index + 1] == quote, chars[index + 2] == quote { return index }
            index += 1
        }
        return nil
    }

    /// The table's text, header included, without the blank lines that
    /// separate it from the next table.
    func section(_ range: Range<Int>) -> String {
        var slice = Array(lines[range])
        while slice.count > 1, slice.last.map(Self.isBlank) == true { slice.removeLast() }
        return slice.joined(separator: "\n")
    }

    /// A string value of `key` inside the table, decoded; nil when absent or
    /// not a single-line string.
    func value(of key: String, in range: Range<Int>) -> String? {
        guard let index = keyLine(key, in: range) else { return nil }
        let line = lines[index]
        guard let equals = line.firstIndex(of: "=") else { return nil }
        return Self.string(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
    }

    func hasMultilineValue(in range: Range<Int>) -> Bool {
        lines[range].contains { $0.contains("\"\"\"") || $0.contains("'''") }
    }

    /// Set `key` to a string, replacing its line or adding one under the
    /// header. Returns the table's range afterwards.
    @discardableResult
    mutating func set(_ key: String, to value: String, in range: Range<Int>) -> Range<Int> {
        let line = "\(key) = " + (key == "command" ? Self.literal(value) : Self.basic(value))
        if let index = keyLine(key, in: range) {
            lines[index] = line
            return range
        }
        // `type` goes first, `command` after it, both under the header.
        let anchor = key == "command" ? keyLine("type", in: range).map { $0 + 1 } : nil
        lines.insert(line, at: anchor ?? range.lowerBound + 1)
        return range.lowerBound ..< range.upperBound + 1
    }

    mutating func remove(_ key: String, in range: Range<Int>) {
        if let index = keyLine(key, in: range) { lines.remove(at: index) }
    }

    mutating func replace(_ range: Range<Int>, with section: String) {
        var replacement = section.components(separatedBy: "\n")
        // Keep the blank lines that separated the table from the next one.
        var tail = range.upperBound
        while tail > range.lowerBound + 1, Self.isBlank(lines[tail - 1]) { tail -= 1 }
        replacement += lines[tail ..< range.upperBound]
        lines.replaceSubrange(range, with: replacement)
    }

    /// Remove a table vibebuddy appended, undoing what `appendTable` added
    /// around it while it is still the last table. Elsewhere its trailing
    /// blank lines go too, so the tables around it keep one separation.
    mutating func removeTable(_ range: Range<Int>, addedBlankLine: Bool, addedFinalNewline: Bool) {
        var lower = range.lowerBound
        if range.upperBound == lines.count {
            if addedBlankLine, lower > 0, Self.isBlank(lines[lower - 1]) { lower -= 1 }
            if addedFinalNewline { trailingNewline = false }
        }
        lines.removeSubrange(lower ..< range.upperBound)
    }

    /// Append `[ui.status_line]` with `body`; says what it added around it.
    @discardableResult
    mutating func appendTable(_ body: [String]) -> (blankLine: Bool, finalNewline: Bool) {
        let blankLine = !lines.isEmpty && !Self.isBlank(lines[lines.count - 1])
        let finalNewline = !lines.isEmpty && !trailingNewline
        if blankLine { lines.append("") }
        lines.append("[ui.status_line]")
        lines += body
        trailingNewline = true
        return (blankLine, finalNewline)
    }

    private static func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    private func keyLine(_ key: String, in range: Range<Int>) -> Int? {
        range.dropFirst().first { Self.keyPath(lines[$0].trimmingCharacters(in: .whitespaces)) == [key] }
    }

    static func normalizedType(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        return ["off", "none", "hidden"].contains(value) ? "disabled" : value
    }

    // MARK: - Lexing

    /// `[a."b".c]` → `["a", "b", "c"]`; nil for anything that is not a
    /// header, such as a nested array inside a multi-line array (`[1, 2],`).
    static func headerName(_ line: String) -> [String]? {
        var body = Substring(line)
        let isArray = body.hasPrefix("[[")
        body = body.dropFirst(isArray ? 2 : 1)
        guard let close = closing(body, isArray: isArray) else { return nil }
        let rest = body[body.index(close, offsetBy: isArray ? 2 : 1)...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
        return keyParts(String(body[..<close]))
    }

    private static func closing(_ body: Substring, isArray: Bool) -> Substring.Index? {
        var quote: Character?
        var index = body.startIndex
        while index < body.endIndex {
            let c = body[index]
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "]" {
                if !isArray { return index }
                let next = body.index(after: index)
                return next < body.endIndex && body[next] == "]" ? index : nil
            }
            index = body.index(after: index)
        }
        return nil
    }

    /// The dotted key a `key = value` line assigns; nil for comments, blank
    /// lines, headers and continuation lines.
    static func keyPath(_ line: String) -> [String]? {
        guard let first = line.first, first != "#", first != "[" else { return nil }
        var quote: Character?
        for index in line.indices {
            let c = line[index]
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "=" { return keyParts(String(line[..<index])) }
        }
        return nil
    }

    private static func keyParts(_ text: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for c in text {
            if let q = quote { if c == q { quote = nil } else { current.append(c) }; continue }
            switch c {
            case "\"", "'": quote = c
            case ".": parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(c)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.contains(where: \.isEmpty) ? nil : parts
    }

    /// A single-line TOML string (basic or literal), trailing comment allowed.
    static func string(_ text: String) -> String? {
        if text.hasPrefix("'''") || text.hasPrefix("\"\"\"") { return nil }
        if text.hasPrefix("'") {
            let body = text.dropFirst()
            guard let end = body.firstIndex(of: "'") else { return nil }
            return String(body[..<end])
        }
        guard text.hasPrefix("\"") else { return nil }
        var result = ""
        var iterator = text.dropFirst().makeIterator()
        while let c = iterator.next() {
            switch c {
            case "\"": return result
            case "\\":
                guard let e = iterator.next() else { return nil }
                switch e {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "b": result.append("\u{8}")
                case "f": result.append("\u{c}")
                case "e": result.append("\u{1b}")
                case "\"", "\\": result.append(e)
                case "u", "U":
                    var hex = ""
                    for _ in 0 ..< (e == "u" ? 4 : 8) { guard let h = iterator.next() else { return nil }; hex.append(h) }
                    guard let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) else { return nil }
                    result.unicodeScalars.append(scalar)
                default: return nil
                }
            default: result.append(c)
            }
        }
        return nil
    }

    /// `'text'` when it can be (no quote or control character), else a basic string.
    static func literal(_ value: String) -> String {
        if !value.contains("'"), !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return "'" + value + "'"
        }
        return basic(value)
    }

    static func basic(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f { out += String(format: "\\u%04X", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
