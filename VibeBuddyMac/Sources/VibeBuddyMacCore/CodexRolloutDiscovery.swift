import Foundation

/// Shared rollout discovery for the Desktop monitor and Settings diagnostics.
///
/// Rollouts live under their *start* date, and a resumed thread keeps appending
/// to that old file. Both callers walk the injected `sessions` root recursively
/// — they must not each invent a date-directory assumption.
///
/// `candidates` keeps the monitor's recency window (what to tail). `latest` is
/// unbounded by mtime so diagnostics can still classify a stale rollout after
/// an app or daemon restart.
///
/// The root is `~/.codex/sessions` (or a test/CODEX_HOME stand-in), never the
/// Codex home itself: that tree also holds `archived_sessions`, cache, backups,
/// and memories.
enum CodexRolloutDiscovery {
    static let recencyWindow: TimeInterval = 30 * 60

    struct Candidate: Equatable {
        let url: URL
        let modifiedAt: Date
    }

    /// Distinguishes "nothing to see" from "could not look". `FileManager.enumerator`
    /// skips unreadable subdirectories without error, so an unreadable root (or a
    /// scan that found no files only because some directories could not be read)
    /// must not collapse into `.empty`.
    enum Lookup: Equatable {
        case found([Candidate])
        case empty
        case unreadable
    }

    enum Latest: Equatable {
        case found(url: URL, modifiedAt: Date)
        case empty
        case unreadable
    }

    /// `window` bounds which files the monitor should tail. Pass `nil` to keep
    /// every rollout so diagnostics can classify stale evidence after a restart.
    static func candidates(
        in root: URL,
        now: Date,
        window: TimeInterval? = recencyWindow,
        fileManager fm: FileManager = .default
    ) -> Lookup {
        guard fm.fileExists(atPath: root.path) else { return .empty }
        guard isReadableDirectory(root, fileManager: fm) else { return .unreadable }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        var files: [Candidate] = []
        var sawUnreadable = false

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                sawUnreadable = true
                return true
            }
        ) else { return .unreadable }

        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                if url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" {
                    return .unreadable
                }
                sawUnreadable = true
                continue
            }

            if values.isDirectory == true {
                if !isReadableDirectory(url, fileManager: fm) {
                    sawUnreadable = true
                    enumerator.skipDescendants()
                }
                continue
            }

            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            if let window, now.timeIntervalSince(modified) > window { continue }
            files.append(Candidate(url: url, modifiedAt: modified))
        }

        if files.isEmpty { return sawUnreadable ? .unreadable : .empty }
        return .found(files)
    }

    /// Diagnostics inspect one file: the newest rollout by mtime, including
    /// files outside the monitor recency window. Same three-way result as
    /// `candidates` — `.unreadable` must not collapse into `.empty`.
    static func latest(
        in root: URL,
        now: Date,
        fileManager fm: FileManager = .default
    ) -> Latest {
        switch candidates(in: root, now: now, window: nil, fileManager: fm) {
        case .empty: return .empty
        case .unreadable: return .unreadable
        case .found(let files):
            guard let newest = files.max(by: { $0.modifiedAt < $1.modifiedAt }) else {
                return .empty
            }
            return .found(url: newest.url, modifiedAt: newest.modifiedAt)
        }
    }

    static func isReadableDirectory(_ url: URL, fileManager fm: FileManager) -> Bool {
        guard fm.isReadableFile(atPath: url.path),
              let attributes = try? fm.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeDirectory,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o444 != 0,
              permissions & 0o111 != 0 else { return false }
        return true
    }
}
