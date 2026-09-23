import Foundation

/// One-time removal of the retired History archive's derived cache (the
/// full-text index, cached transcripts, saved summaries and favorites under
/// `SessionHistory/`). Only these fixed, VibeBuddy-owned locations are ever
/// deleted; agent transcript roots are never touched. Safe when nothing is
/// there, and cheap once it is gone, so it simply runs on every launch.
public enum LegacyHistoryCleanup {
    public struct Result: Equatable, Sendable {
        public var removed: [String]
        public var bytesFreed: Int64
    }

    /// The locations for this run. An E2E run cleans only its own root; an
    /// ordinary run cleans the user's cache and the reader's old temp dirs.
    public static func targets(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               fileManager fm: FileManager = .default) -> [URL] {
        if let root = environment["VIBEBUDDY_E2E_ROOT"] {
            // Same rule as E2ERunConfiguration: an absolute path that is not
            // the filesystem root; anything else cleans nothing.
            guard root.hasPrefix("/"), root != "/", !root.contains("\0") else { return [] }
            return [URL(fileURLWithPath: root).appendingPathComponent("history")]
        }
        var result = [home.appendingPathComponent("Library/Application Support/VibeBuddy/SessionHistory")]
        let temps = (try? fm.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        result += temps.filter { $0.lastPathComponent.hasPrefix("vibebuddy-history-") }
        return result
    }

    @discardableResult
    public static func run(_ targets: [URL], fileManager fm: FileManager = .default) -> Result {
        var result = Result(removed: [], bytesFreed: 0)
        for target in targets {
            guard (try? target.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil else { continue }
            let bytes = allocatedSize(of: target, fileManager: fm)
            // A symlink is removed as a link; its destination is left alone.
            guard (try? fm.removeItem(at: target)) != nil else { continue }
            result.removed.append(target.path)
            result.bytesFreed += bytes
        }
        return result
    }

    private static func allocatedSize(of url: URL, fileManager fm: FileManager) -> Int64 {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        var total = Int64(values.totalFileAllocatedSize ?? 0)
        guard let items = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return total }
        for case let item as URL in items {
            total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
