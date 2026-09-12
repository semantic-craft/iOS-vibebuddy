import Foundation
import VibeBuddyKit

/// Cursor's agent transcripts: where they are, and what one line means.
///
/// Cursor writes one JSONL file per conversation at
/// `~/.cursor/projects/<flattened project path>/agent-transcripts/<id>/<id>.jsonl`
/// (a flat `<id>.jsonl` in the same directory on older builds). It is also the
/// file Cursor's own hooks name in `transcript_path`.
///
/// Read on Cursor 3.20, a transcript holds exactly three line shapes and nothing
/// else — in particular there are no tool *results*:
///
/// ```
/// {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>…</timestamp>\n<user_query>…</user_query>"}]}}
/// {"role":"assistant","message":{"content":[{"type":"text","text":…},{"type":"tool_use","name":"Shell","input":{…}}]}}
/// {"type":"turn_ended","status":"success"}
/// ```
///
/// `turn_ended` is what makes this a usable progress source: it marks the turn
/// boundary explicitly, with `success` / `error` / `aborted` and an optional
/// `error` string, so the three states do not have to be guessed from silence.
public enum CursorTranscripts {

    public static func projectsRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".cursor/projects", isDirectory: true)
    }

    /// One conversation's transcript on disk.
    public struct Located: Equatable, Sendable {
        public let conversationID: String
        public let url: URL
        /// The project the flattened directory name stands for, when it could be
        /// resolved against the filesystem. Nil for `empty-window` and for a
        /// path that no longer exists.
        public let project: String?
        public let modifiedAt: Date
        public let size: Int

        public init(conversationID: String, url: URL, project: String?, modifiedAt: Date, size: Int) {
            self.conversationID = conversationID
            self.url = url
            self.project = project
            self.modifiedAt = modifiedAt
            self.size = size
        }
    }

    /// Every transcript under `root`, newest first.
    public static func discover(
        root: URL = projectsRoot(),
        fileManager fm: FileManager = .default
    ) -> [Located] {
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return [] }
        var found: [Located] = []
        for project in projects {
            let directory = project.appendingPathComponent("agent-transcripts", isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            let path = projectPath(forDirectoryName: project.lastPathComponent, fileManager: fm)
            for entry in entries {
                // `<id>/<id>.jsonl` (3.x) and a flat `<id>.jsonl` (older) both count.
                let candidates: [URL] = entry.pathExtension == "jsonl"
                    ? [entry]
                    : [entry.appendingPathComponent(entry.lastPathComponent + ".jsonl")]
                for file in candidates {
                    let id = file.deletingPathExtension().lastPathComponent
                    guard !id.isEmpty,
                          let attributes = try? fm.attributesOfItem(atPath: file.path),
                          (attributes[.type] as? FileAttributeType) == .typeRegular
                    else { continue }
                    found.append(Located(
                        conversationID: id, url: file, project: path,
                        modifiedAt: (attributes[.modificationDate] as? Date) ?? .distantPast,
                        size: (attributes[.size] as? NSNumber)?.intValue ?? 0))
                }
            }
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Undo Cursor's project-directory flattening.
    ///
    /// Cursor names the directory after the absolute path with every `/` turned
    /// into `-`, which is lossy: `Users-me-Projects-famotype-macos` could be
    /// `/Users/me/Projects/famotype-macos` or `/Users/me/Projects/famotype/macos`.
    /// So the name is not "parsed" — it is resolved against the filesystem, one
    /// segment at a time, taking the first reading that actually exists. A name
    /// nothing on disk matches (a deleted project, Cursor's own `empty-window`)
    /// resolves to nil rather than to a guess.
    public static func projectPath(
        forDirectoryName name: String,
        fileManager fm: FileManager = .default
    ) -> String? {
        guard name != "empty-window", !name.isEmpty else { return nil }
        let parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        return resolve(parts: parts, prefix: "", fileManager: fm)
    }

    /// Depth-first over the two readings of each `-`: a path separator, or a
    /// literal hyphen inside one component. Pruned by "does this directory
    /// exist", which keeps the search to a handful of probes in practice.
    private static func resolve(parts: [String], prefix: String, fileManager fm: FileManager) -> String? {
        guard let head = parts.first else { return nil }
        let path = prefix + "/" + head
        if parts.count == 1 {
            return isDirectory(path, fileManager: fm) ? path : nil
        }
        // Separator first: the common case, and the shortest components.
        if isDirectory(path, fileManager: fm),
           let resolved = resolve(parts: Array(parts.dropFirst()), prefix: path, fileManager: fm) {
            return resolved
        }
        // Then a literal hyphen: fold the next part into this component.
        var folded = Array(parts.dropFirst())
        folded[0] = head + "-" + folded[0]
        return resolve(parts: folded, prefix: prefix, fileManager: fm)
    }

    private static func isDirectory(_ path: String, fileManager fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Lines

    /// What one transcript line says about the conversation.
    public enum Line: Equatable, Sendable {
        /// A turn began; the text is the person's own query, unwrapped from the
        /// `<user_query>` envelope Cursor writes around it.
        case prompt(String)
        /// The agent said something. Bounded — this becomes the row's line.
        case assistantText(String)
        /// The agent called a tool. The name is Cursor's, not yet canonical.
        case toolUse(name: String, detail: String?)
        /// The turn ended. `success` / `error` / `aborted`, plus Cursor's own
        /// error text when it gave one.
        case turnEnded(status: String, error: String?)
    }

    public static func parse(line raw: String) -> [Line] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }

        if let type = object["type"] as? String, type == "turn_ended" {
            return [.turnEnded(status: (object["status"] as? String) ?? "success",
                               error: nonEmpty(object["error"] as? String))]
        }
        guard let role = object["role"] as? String,
              let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return [] }

        var lines: [Line] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                guard let text = nonEmpty(block["text"] as? String) else { continue }
                if role == "user" {
                    lines.append(.prompt(userQuery(in: text)))
                } else {
                    lines.append(.assistantText(String(text.prefix(600))))
                }
            case "tool_use":
                guard let name = nonEmpty(block["name"] as? String) else { continue }
                lines.append(.toolUse(name: name,
                                      detail: toolDetail(block["input"] as? [String: Any])))
            default:
                continue
            }
        }
        return lines
    }

    /// The person's words, without the `<timestamp>` / `<user_query>` wrapper
    /// Cursor prepends. A line that carries no wrapper is already the query.
    public static func userQuery(in text: String) -> String {
        let opening = "<user_query>"
        let closing = "</user_query>"
        guard let start = text.range(of: opening), let end = text.range(of: closing),
              start.upperBound <= end.lowerBound else {
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        }
        return String(text[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
    }

    /// A one-line summary of what the tool was asked to do, for the recent
    /// dialogue view. Cursor records no tool results, so this is all there is.
    static func toolDetail(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["command", "path", "file_path", "pattern", "query", "url",
                    "description", "current_step", "prompt"] {
            if let value = nonEmpty(input[key] as? String) { return String(value.prefix(200)) }
        }
        return nil
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
