import Foundation
import VibeBuddyKit

/// Finds handoff documents under the checkouts sessions have run in. Reads
/// only `<dir>/.scratch/*/handoffs/*.md` (the `.scratch` entry itself may be
/// a symlink to a main checkout, as agent worktrees link it), only the first
/// lines of each file, and never a file that resolves outside that `.scratch`.
/// Results are cached per handoffs directory by its modification time.
struct HandoffScanner {
    static let maxRecords = 200
    static let maxFileBytes = 64 * 1024
    static let headerLines = 8

    private struct Cached { var directoryModified: Date; var records: [HandoffRecord] }
    private var cache: [String: Cached] = [:]

    mutating func scan(directories: [String]) -> [HandoffRecord] {
        let fm = FileManager.default
        var out: [HandoffRecord] = []
        var seenRoots = Set<String>()
        for directory in directories where directory.hasPrefix("/") {
            let scratchLink = URL(fileURLWithPath: directory).appendingPathComponent(".scratch")
            let scratch = scratchLink.resolvingSymlinksInPath().standardizedFileURL
            guard seenRoots.insert(scratch.path).inserted,
                  let efforts = try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for effort in efforts {
                let handoffs = effort.appendingPathComponent("handoffs")
                guard let modified = try? fm.attributesOfItem(atPath: handoffs.path)[.modificationDate] as? Date else { continue }
                if let cached = cache[handoffs.path], cached.directoryModified == modified {
                    out += cached.records; continue
                }
                let records = Self.records(in: handoffs, scratch: scratch)
                cache[handoffs.path] = Cached(directoryModified: modified, records: records)
                out += records
            }
        }
        let live = Set(out.map(\.path))
        cache = cache.filter { entry in entry.value.records.allSatisfy { live.contains($0.path) } || entry.value.records.isEmpty }
        return Array(out.sorted { $0.writtenAt == $1.writtenAt ? $0.path < $1.path : $0.writtenAt > $1.writtenAt }.prefix(Self.maxRecords))
    }

    private static func records(in handoffs: URL, scratch: URL) -> [HandoffRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: handoffs, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { url -> HandoffRecord? in
            guard url.pathExtension == "md",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, (values.fileSize ?? 0) <= maxFileBytes,
                  url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(scratch.path + "/") else { return nil }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 4096) else { return nil }
            return parse(String(decoding: data, as: UTF8.self), path: url.standardizedFileURL.path, modified: modified)
        }
    }

    /// The first `headerLines` lines. `Source session:` must be the first line
    /// for the file to count as a handoff at all (ADR-0019's contract).
    static func parse(_ text: String, path: String, modified: Date) -> HandoffRecord? {
        let lines = text.split(separator: "\n", maxSplits: headerLines, omittingEmptySubsequences: false).prefix(headerLines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, first.hasPrefix("Source session:") else { return nil }
        func value(_ label: String) -> String? {
            guard let line = lines.first(where: { $0.hasPrefix(label + ":") }) else { return nil }
            let value = line.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : String(value.prefix(512))
        }
        let source = value("Source session").flatMap { raw -> String? in
            guard raw != "unknown", let reference = try? HistorySessionReference(raw) else { return nil }
            return reference.key
        }
        return HandoffRecord(path: path, sourceKey: source, ticket: value("Ticket"), branch: value("Branch"),
                             worktree: value("Worktree"), writtenAt: modified)
    }
}
