import Foundation

/// A JSON value that keeps what `JSONSerialization` throws away: object key
/// order and the exact text of numbers. The hook installer edits files other
/// tools and people own (`settings.json`, `hooks.json`), so everything it does
/// not mean to change must come back out as it went in.
///
/// `serialized()` writes the layout Python's `json.dumps(indent=2,
/// ensure_ascii=False)` produced, which is what the retired Python installers
/// left on disk — a file they wrote re-serializes byte for byte.
indirect enum OrderedJSON: Equatable, Sendable {
    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// The number exactly as written, so `1.0` never turns into `1`.
    case number(String)
    case bool(Bool)
    case null

    struct Member: Equatable, Sendable {
        var key: String
        var value: OrderedJSON
    }

    struct ParseError: Error, CustomStringConvertible {
        let offset: Int
        let reason: String
        var description: String { "invalid JSON at byte \(offset): \(reason)" }
    }

    // MARK: - Building

    static func obj(_ pairs: KeyValuePairs<String, OrderedJSON>) -> OrderedJSON {
        .object(pairs.map { Member(key: $0.key, value: $0.value) })
    }

    static func int(_ value: Int) -> OrderedJSON { .number(String(value)) }

    // MARK: - Reading

    var members: [Member]? { if case .object(let m) = self { return m }; return nil }
    var elements: [OrderedJSON]? { if case .array(let a) = self { return a }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var isObject: Bool { members != nil }

    /// The last member with this key (JSON leaves duplicates undefined; the
    /// last one is what every mainstream parser keeps).
    subscript(key: String) -> OrderedJSON? {
        get { members?.last(where: { $0.key == key })?.value }
        set {
            guard case .object(var m) = self else { return }
            if let newValue {
                if let index = m.lastIndex(where: { $0.key == key }) {
                    m[index].value = newValue
                } else {
                    m.append(Member(key: key, value: newValue))
                }
            } else {
                m.removeAll { $0.key == key }
            }
            self = .object(m)
        }
    }

    var keys: [String] { members?.map(\.key) ?? [] }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        // A UTF-8 byte order mark is tolerated, as Python's reader tolerates it.
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw ParseError(offset: parser.index, reason: "trailing content")
        }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func fail(_ reason: String) -> ParseError { ParseError(offset: index, reason: reason) }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < 512 else { throw fail("nesting too deep") }
            skipWhitespace()
            guard index < bytes.count else { throw fail("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<index + expected.count]) == expected else { throw fail("expected \(word)") }
            index += expected.count
        }

        mutating func object(depth: Int) throws -> OrderedJSON {
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object([]) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("expected key") }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("expected :") }
                index += 1
                members.append(Member(key: key, value: try value(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw fail("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw fail("expected , or }")
            }
        }

        mutating func array(depth: Int) throws -> OrderedJSON {
            index += 1
            var elements: [OrderedJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array([]) }
            while true {
                elements.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw fail("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                throw fail("expected , or ]")
            }
        }

        mutating func number() throws -> String {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            func digits() -> Int {
                let begin = index
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                return index - begin
            }
            guard digits() > 0 else { throw fail("invalid number") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw fail("invalid fraction") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw fail("invalid exponent") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { throw fail("invalid \\u escape") }
            index += 4
            return value
        }

        mutating func string() throws -> String {
            index += 1
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw fail("unterminated string") }
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(bytes: out, encoding: .utf8) else { throw fail("invalid UTF-8") }
                    return text
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw fail("unterminated escape") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xD800...0xDBFF).contains(scalar) {
                            // A lone surrogate is not text; refuse the file rather
                            // than silently rewrite it as U+FFFD.
                            guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"),
                                  bytes[index + 1] == UInt8(ascii: "u") else { throw fail("lone surrogate") }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw fail("invalid surrogate pair") }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(scalar) {
                            throw fail("lone surrogate")
                        }
                        guard let character = Unicode.Scalar(scalar) else { throw fail("invalid \\u escape") }
                        out.append(contentsOf: Array(String(character).utf8))
                    default: throw fail("invalid escape")
                    }
                default:
                    guard byte >= 0x20 else { throw fail("control character in string") }
                    out.append(byte)
                }
            }
        }
    }

    // MARK: - Writing

    /// Python `json.dumps(value, indent=2, ensure_ascii=False)` plus a newline.
    func serialized() -> Data {
        var out = ""
        write(into: &out, indent: 0)
        out += "\n"
        return Data(out.utf8)
    }

    private func write(into out: inout String, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let text): out += text
        case .string(let text): Self.writeString(text, into: &out)
        case .array(let elements):
            guard !elements.isEmpty else { out += "[]"; return }
            let pad = String(repeating: " ", count: indent + 2)
            out += "[\n"
            for (offset, element) in elements.enumerated() {
                out += pad
                element.write(into: &out, indent: indent + 2)
                out += offset == elements.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            let pad = String(repeating: " ", count: indent + 2)
            out += "{\n"
            for (offset, member) in members.enumerated() {
                out += pad
                Self.writeString(member.key, into: &out)
                out += ": "
                member.value.write(into: &out, indent: indent + 2)
                out += offset == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        }
    }

    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
