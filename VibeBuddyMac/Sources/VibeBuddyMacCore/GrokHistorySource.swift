import CryptoKit
import Foundation

/// Grok 1.0.30's official inventory only. Never reads updates.jsonl or exports
/// conversations: the three-session TUI fidelity gate was not completed.
public enum GrokHistorySource {
    public static let coverage = "Grok Build: official list and titles only; no transcript or full-text search. List dates have day precision."
    static let noTranscript = "该来源无全文 (Grok Build: list and title only; no transcript)."
    static let sandboxProfile = "(version 1)(allow default)(deny file-write*)(deny process-fork)"
    struct Inventory {
        var sessions: [SessionHistorySession] = []
        var issues: [String] = []
    }

    /// Directory names locate workspaces only; all record metadata comes from
    /// `sessions list`. The local directory verifies which cwd owns each row,
    /// since the CLI may also list siblings and remote-only sessions.
    static func scan(home: URL) -> Inventory {
        let root = home.appendingPathComponent("sessions").resolvingSymlinksInPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return Inventory() }
        guard let executable = executable(), fm.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            return Inventory(issues: ["Grok history unavailable: official CLI or read-only process sandbox unavailable."])
        }
        guard let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            return Inventory(issues: ["Grok history unavailable: workspace directory cannot be enumerated."])
        }
        var result = Inventory()
        let deadline = Date().addingTimeInterval(15)
        for directory in directories.sorted(by: { $0.path < $1.path }) {
            guard let properties = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  properties.isDirectory == true, properties.isSymbolicLink != true else { continue }
            guard let cwd = directory.lastPathComponent.removingPercentEncoding,
                  cwd.hasPrefix("/"), !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  fm.fileExists(atPath: cwd) else {
                result.issues.append("Grok history: a workspace path is unavailable; its inventory was not refreshed.")
                continue
            }
            let timeout = min(3, deadline.timeIntervalSinceNow)
            guard timeout > 0.2 else {
                result.issues.append("Grok history: workspace inventory time limit reached; coverage is partial.")
                break
            }
            do {
                var environment = ProcessInfo.processInfo.environment
                environment["GROK_HOME"] = home.path
                let output = try POSIXCommandSupervisor().run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                    arguments: ["-p", sandboxProfile, executable.path, "--cwd", cwd, "sessions", "list", "-n", "200"],
                    environment: environment, timeout: timeout, outputLimit: min(SessionHistoryParser.byteLimit, 1024 * 1024))
                guard output.exitedSuccessfully, let text = String(data: output.standardOutput, encoding: .utf8) else {
                    result.issues.append("Grok history: protected official list failed; no unprotected retry was attempted.")
                    continue
                }
                // CLI diagnostics can contain authentication details. Never expose them.
                if !output.standardError.isEmpty { result.issues.append("Grok history: official list reported diagnostics; inventory may be partial.") }
                var parsed = parse(text, cwd: cwd, directory: directory)
                var unmatched = false
                parsed.sessions.removeAll { session in
                    let values = try? URL(fileURLWithPath: session.sourcePath).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values?.isDirectory == true, values?.isSymbolicLink != true { return false }
                    unmatched = true
                    return true
                }
                if unmatched { parsed.issues.append("Grok history: list row has no matching local workspace directory; project was not guessed.") }
                result.sessions += parsed.sessions
                result.issues += parsed.issues
            } catch {
                result.issues.append("Grok history: protected official list failed or exceeded its time/output limit.")
            }
        }
        return result
    }

    /// Fixed text format verified against grok 1.0.30. Reject an entire malformed
    /// row; never infer a session ID, date, source, or project from its title.
    static func parse(_ text: String, cwd: String, directory: URL) -> Inventory {
        var result = Inventory()
        let pattern = #"^([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s+(\d{4}-\d{2}-\d{2})\s+(\d{4}-\d{2}-\d{2})\s+(local|remote)\s+(.+)$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX"); date.calendar = Calendar(identifier: .gregorian)
        date.dateFormat = "yyyy-MM-dd"; date.isLenient = false
        var seen = Set<String>()
        var count = 0
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "(no label)" || line.hasPrefix("Label: ") || line == "No sessions found." { continue }
            if line.split(whereSeparator: \.isWhitespace).joined(separator: " ") == "SESSION ID CREATED UPDATED SOURCE SUMMARY" { continue }
            guard !line.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let idRange = Range(match.range(at: 1), in: line),
                  let createdRange = Range(match.range(at: 2), in: line),
                  let updatedRange = Range(match.range(at: 3), in: line),
                  let sourceRange = Range(match.range(at: 4), in: line),
                  let titleRange = Range(match.range(at: 5), in: line),
                  let created = date.date(from: String(line[createdRange])), date.string(from: created) == line[createdRange],
                  let updated = date.date(from: String(line[updatedRange])), date.string(from: updated) == line[updatedRange] else {
                result.issues.append("Grok history: unrecognized official list row \(index + 1) omitted.")
                continue
            }
            count += 1
            guard line[sourceRange] == "local" else { continue }
            let id = String(line[idRange]).lowercased()
            guard seen.insert(id).inserted else {
                result.issues.append("Grok history: duplicate native ID omitted.")
                result.sessions.removeAll { $0.nativeSessionID == id }
                continue
            }
            let path = directory.appendingPathComponent(id).path
            var session = SessionHistorySession(id: "grokBuild:" + id, nativeSessionID: id, agent: .grokBuild,
                projectPath: cwd, title: String(line[titleRange].prefix(120)), sourcePath: path, updatedAt: updated,
                messages: [], warnings: [coverage], source: "official-list")
            session.sourceRevision = "list-row:" + SHA256.hash(data: Data((path + "\n" + line).utf8)).map { String(format: "%02x", $0) }.joined()
            result.sessions.append(session)
        }
        if count >= 200 { result.issues.append("Grok history: official list reached its 200-row limit; coverage may be partial.") }
        return result
    }

    private static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".local/bin/grok").path, home.appendingPathComponent(".grok/bin/grok").path,
                     "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
        return paths.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }
}
