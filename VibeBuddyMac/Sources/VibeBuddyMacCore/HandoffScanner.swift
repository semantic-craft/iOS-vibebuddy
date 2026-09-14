import Foundation
import VibeBuddyKit

/// Finds handoff documents under the checkouts sessions have run in. Reads
/// only `<dir>/.scratch/*/handoffs/*.md` (the `.scratch` entry itself may be
/// a symlink to a main checkout, as agent worktrees link it), only the first
/// lines of each file, and never a file that resolves outside that `.scratch`.
/// Headers are cached by each eligible file's modification time and size.
struct HandoffScanner {
    static let maxRecords = 200
    static let maxFileBytes = 64 * 1024
    static let headerLines = 8

    private struct Stamp: Equatable { var modified: Date; var size: Int }
    private struct Cached { var files: [String: Stamp]; var records: [HandoffRecord] }
    private var cache: [String: Cached] = [:]

    mutating func scan(directories: [String]) -> [HandoffRecord] {
        let fm = FileManager.default
        var out: [HandoffRecord] = []
        var seenRoots = Set<String>()
        var liveDirectories = Set<String>()
        for directory in directories where directory.hasPrefix("/") {
            let scratchLink = URL(fileURLWithPath: directory).appendingPathComponent(".scratch")
            let scratch = scratchLink.resolvingSymlinksInPath().standardizedFileURL
            guard seenRoots.insert(scratch.path).inserted,
                  let efforts = try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for effort in efforts {
                let handoffs = effort.appendingPathComponent("handoffs")
                let files = Self.files(in: handoffs, scratch: scratch)
                liveDirectories.insert(handoffs.path)
                if let cached = cache[handoffs.path], cached.files == files {
                    out += cached.records; continue
                }
                let records = Self.records(files)
                cache[handoffs.path] = Cached(files: files, records: records)
                out += records
            }
        }
        cache = cache.filter { liveDirectories.contains($0.key) }
        return Array(out.sorted { $0.writtenAt == $1.writtenAt ? $0.path < $1.path : $0.writtenAt > $1.writtenAt }.prefix(Self.maxRecords))
    }

    private static func files(in handoffs: URL, scratch: URL) -> [String: Stamp] {
        let fm = FileManager.default
        guard handoffs.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(scratch.path + "/"),
              let files = try? fm.contentsOfDirectory(at: handoffs, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [:] }
        var stamps: [String: Stamp] = [:]
        for url in files {
            guard url.pathExtension == "md",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, (values.fileSize ?? 0) <= maxFileBytes,
                  url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(scratch.path + "/") else { continue }
            stamps[url.standardizedFileURL.path] = Stamp(modified: modified, size: values.fileSize ?? 0)
        }
        return stamps
    }

    private static func records(_ files: [String: Stamp]) -> [HandoffRecord] {
        files.compactMap { path, stamp in
            let url = URL(fileURLWithPath: path)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 4096) else { return nil }
            return parse(String(decoding: data, as: UTF8.self), path: path, modified: stamp.modified)
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
