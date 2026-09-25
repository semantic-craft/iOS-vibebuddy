import XCTest

/// Runs Apple's accessibility audit on one screen and appends every issue as a JSON line.
enum Audit {
    static func run(_ app: XCUIApplication, screen: String, out: String, test: XCTestCase) {
        var lines: [String] = []
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                let e = issue.element
                let row: [String: Any] = [
                    "screen": screen,
                    "type": typeName(issue.auditType),
                    "desc": issue.compactDescription,
                    "label": e?.label ?? "",
                    "id": e?.identifier ?? "",
                    "elType": e.map { "\($0.elementType.rawValue)" } ?? "",
                    "frame": e.map { NSCoder.string(for: $0.frame) } ?? "",
                ]
                if let d = try? JSONSerialization.data(withJSONObject: row), let s = String(data: d, encoding: .utf8) { lines.append(s) }
                return true   // record ourselves, don't fail
            }
        } catch {
            let row: [String: Any] = ["screen": screen, "type": "AUDIT-ERROR", "desc": "\(error)"]
            if let d = try? JSONSerialization.data(withJSONObject: row), let s = String(data: d, encoding: .utf8) { lines.append(s) }
        }
        if lines.isEmpty { lines.append("{\"screen\":\"\(screen)\",\"type\":\"CLEAN\"}") }
        append(lines.joined(separator: "\n") + "\n", to: out + "/issues.jsonl")
        append("===== \(screen)\n" + app.debugDescription + "\n", to: out + "/tree.txt")
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: out + "/\(screen).png"))
    }

    static func typeName(_ t: XCUIAccessibilityAuditType) -> String {
        switch t {
        case .contrast: "contrast"
        case .elementDetection: "elementDetection"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "description"
        case .dynamicType: "dynamicType"
        case .textClipped: "textClipped"
        case .trait: "trait"
        default: "other(\(t.rawValue))"
        }
    }

    static func append(_ s: String, to path: String) {
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); h.closeFile() }
        else { try? s.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
