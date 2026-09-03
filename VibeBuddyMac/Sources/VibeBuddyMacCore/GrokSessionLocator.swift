import Foundation

/// Finds the directory Grok Build keeps one session's files in.
///
/// Grok stores a session at `~/.grok/sessions/<encoded cwd>/<session id>/`,
/// where the directory name is the working directory percent-encoded against
/// RFC 3986's unreserved set. Unlike Claude Code's project-directory naming the
/// encoding is lossless, so the fast path is a single `stat` — no scan.
///
/// The encoding rule and its rationale are ported from `agent-session-kit`
/// (`AgentSessionLive/Adapters/Grok/GrokSessionsPath.swift`); the scan fallback
/// mirrors `agent-sessions`' `GrokSessionDiscovery.swift`, which exists because
/// an encoded cwd over 255 bytes is replaced by a `<slug>-<hash>` directory
/// whose real path lives in a sibling `.cwd` file.
public enum GrokSessionLocator {

    /// The characters Grok leaves unescaped: RFC 3986's unreserved set.
    /// Checked against the real store — `-`, `.`, `_` and `~` appear literally
    /// in directory names there, everything else outside `[A-Za-z0-9]` escaped.
    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Encodes a working directory the way Grok names its session directory.
    public static func encode(cwd: String) -> String? {
        cwd.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    /// `<grok home>/sessions` — `GrokHome.url` resolves `$GROK_HOME`.
    public static func sessionsRoot(grokHome: URL) -> URL {
        grokHome.appendingPathComponent("sessions", isDirectory: true)
    }

    /// The session directory for `sessionID`, or nil when nothing on disk
    /// matches. Tries the encoded-cwd path first and only then scans, so the
    /// common case costs one file-existence check.
    public static func locate(sessionID: String, cwd: String?, grokHome: URL) -> URL? {
        guard !sessionID.isEmpty, !sessionID.contains("/"), sessionID != ".", sessionID != ".."
        else { return nil }
        let root = sessionsRoot(grokHome: grokHome)

        if let cwd, let encoded = encode(cwd: cwd) {
            let direct = root.appendingPathComponent(encoded, isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            if isSessionDirectory(direct) { return direct }
        }

        // `<slug>-<hash>` naming, or a hook that never told us the cwd.
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        for child in children {
            let candidate = child.appendingPathComponent(sessionID, isDirectory: true)
            if isSessionDirectory(candidate) { return candidate }
        }
        return nil
    }

    /// The session directory a hook-supplied `transcriptPath` points into. Grok
    /// names `updates.jsonl` there, so the directory is that file's parent; a
    /// path that already is the session directory is accepted as-is.
    public static func directory(forTranscriptPath path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        if isSessionDirectory(url) { return url }
        let parent = url.deletingLastPathComponent()
        return isSessionDirectory(parent) ? parent : nil
    }

    /// A directory is a session when Grok has written either of the two files it
    /// creates at session start. Requiring both would miss a session observed
    /// between the two writes.
    static func isSessionDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("summary.json").path)
            || fm.fileExists(atPath: url.appendingPathComponent("updates.jsonl").path)
    }
}
