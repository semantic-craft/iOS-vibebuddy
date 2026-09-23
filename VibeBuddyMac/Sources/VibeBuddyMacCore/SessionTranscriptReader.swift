import Foundation
import Darwin

/// Reads one agent session's local transcript by its exact native key
/// (`claude-code:<id>`, `codex:<id>`, `cursor:<id>`). It serves the Mac
/// reading pane (ADR-0024), the phone's `GET /history` (ADR-0029) and
/// `vibebuddy-mcp show`. Read only: it writes no files, keeps no index and
/// never scans transcripts it was not asked for. The only state is an
/// in-memory map from key to file and the last parsed transcript.
public actor SessionTranscriptReader {
    private let roots: [(url: URL, agent: SessionHistoryAgent)]
    private var located: [String: URL] = [:]
    private var slot: (path: String, revision: String, transcript: HistoryTranscript)?

    public init(claudeHome: URL? = nil, codexHome: URL? = nil, cursorHome: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude = claudeHome ?? environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let codex = codexHome ?? environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let cursor = cursorHome.map { $0.appendingPathComponent("projects") }
            ?? environment["VIBEBUDDY_CURSOR_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("projects") }
            ?? CursorTranscripts.projectsRoot(home: home)
        let configured: [(URL, SessionHistoryAgent)] = [
            (claude.appendingPathComponent("projects"), .claude),
            (codex.appendingPathComponent("sessions"), .codex),
            (codex.appendingPathComponent("archived_sessions"), .codex),
            (cursor, .cursor)]
        roots = configured.map { (url: $0.0.resolvingSymlinksInPath(), agent: $0.1) }
    }

    /// An isolated E2E run reads the agent homes under
    /// `$VIBEBUDDY_E2E_ROOT/agents/`, never the person's own.
    public static func forCurrentRun(environment: [String: String] = ProcessInfo.processInfo.environment) -> SessionTranscriptReader {
        guard let root = environment["VIBEBUDDY_E2E_ROOT"].map({ URL(fileURLWithPath: $0) }) else {
            return SessionTranscriptReader(environment: environment)
        }
        return SessionTranscriptReader(claudeHome: root.appendingPathComponent("agents/claude"),
                                       codexHome: root.appendingPathComponent("agents/codex"),
                                       cursorHome: root.appendingPathComponent("agents/cursor"),
                                       environment: environment)
    }

    /// A filesystem revision: device, inode, size, mtime and ctime. A rewrite
    /// that keeps the modification date still changes it.
    static func sourceRevision(_ file: URL) -> String? {
        var value = stat()
        guard lstat(file.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
        return "fs1|\(value.st_dev)|\(value.st_ino)|\(value.st_size)|\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)|\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }

    /// Parses the source on every new revision; the same revision returns the
    /// previous parse, so paging one transcript does not re-read it.
    public func readTranscript(key: String) throws -> HistoryTranscript {
        let reference = try HistorySessionReference(key)
        guard reference.agent.supportsTranscript else { throw HistoryToolError.executionFailed(SessionHistoryAgent.grokNoTranscript) }
        let file = try locate(reference)
        guard let revision = Self.sourceRevision(file),
              let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            located[reference.key] = nil
            throw HistoryToolError.executionFailed("Source unavailable.")
        }
        if let slot, slot.path == file.path, slot.revision == revision { return slot.transcript }
        var session = try SessionHistoryParser.read(url: file, agent: reference.agent, updatedAt: modified)
        guard Self.sourceRevision(file) == revision else { throw HistoryToolError.executionFailed("Source changed while reading; retry for a consistent revision.") }
        guard session.nativeSessionID == reference.nativeID else { throw HistoryToolError.executionFailed("Source identity does not match the requested key.") }
        session.sourceArchived = reference.agent == .codex && file.deletingLastPathComponent().lastPathComponent == "archived_sessions"
        session.sourceRevision = revision
        let transcript = HistoryTranscript(session: session, provenance: "source")
        slot = (file.path, revision, transcript)
        return transcript
    }

    /// The cached file while it is still a regular file, else a fresh lookup
    /// by native file name only — never by parsing other conversations.
    private func locate(_ reference: HistorySessionReference) throws -> URL {
        if let cached = located[reference.key], Self.isPlainFile(cached) { return cached }
        located[reference.key] = nil
        var candidates: [URL] = []
        let fm = FileManager.default
        for (root, agent) in roots where agent == reference.agent {
            var found: [URL] = []
            switch agent {
            case .claude:
                // `projects/<encoded cwd>/<id>.jsonl`; subagents live one level deeper.
                for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                    found.append(project.appendingPathComponent(reference.nativeID + ".jsonl"))
                }
            case .cursor:
                guard !reference.nativeID.hasPrefix("bc-") else { continue }
                for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                    let transcripts = project.appendingPathComponent("agent-transcripts")
                    found.append(transcripts.appendingPathComponent(reference.nativeID).appendingPathComponent(reference.nativeID + ".jsonl"))
                    found.append(transcripts.appendingPathComponent(reference.nativeID + ".jsonl"))
                }
            case .codex:
                // `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`, flat in archived_sessions.
                guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in iterator where file.pathExtension == "jsonl" {
                    let stem = file.deletingPathExtension().lastPathComponent
                    if stem == reference.nativeID || stem.hasSuffix("-" + reference.nativeID) { found.append(file) }
                }
            case .grokBuild:
                continue
            }
            candidates += found.filter { Self.isPlainFile($0) && $0.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") }
        }
        guard candidates.count == 1 else {
            throw HistoryToolError.executionFailed(candidates.isEmpty ? "Unknown session key." : "Ambiguous session key: multiple source files.")
        }
        located[reference.key] = candidates[0]
        return candidates[0]
    }

    /// lstat, not URL resource values: a URL caches those, and a cached path
    /// must be seen to disappear. A symlink is never a plain file.
    private static func isPlainFile(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
    }
}
