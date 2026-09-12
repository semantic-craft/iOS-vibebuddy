import Foundation
import CryptoKit

/// Local history is a read-only projection, independent of the live Session reducer.
public actor SessionHistoryRepository {
    private struct Entry: Codable { var modified: Date; var size: Int; var session: SessionHistorySession }
    private struct Cache: Codable { var version: Int = 4; var entries: [String: Entry]; var pendingPaths: Set<String>? = nil }
    private let roots: [(URL, SessionHistoryAgent)]
    private let directory: URL
    private let refreshByteBudget: Int
    private var entries: [String: Entry] = [:]
    private var favorites = Set<String>()
    private var issues: [String] = []
    private var refreshedAt: Date?
    private var pendingPaths = Set<String>()
    private var loaded = false
    private var indexDirty = false
    public init(claudeHome: URL? = nil, codexHome: URL? = nil, cacheDirectory: URL? = nil, refreshByteBudget: Int = 256 * 1024 * 1024) {
        self.refreshByteBudget = max(1, refreshByteBudget)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let claude = claudeHome ?? env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let codex = codexHome ?? env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        roots = [(claude.appendingPathComponent("projects").resolvingSymlinksInPath(), .claude), (codex.appendingPathComponent("sessions").resolvingSymlinksInPath(), .codex), (codex.appendingPathComponent("archived_sessions").resolvingSymlinksInPath(), .codex)]
        directory = cacheDirectory ?? home.appendingPathComponent("Library/Application Support/VibeBuddy/SessionHistory")
    }
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: directory.appendingPathComponent("favorites.json")), let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) { favorites = decoded }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")), let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 4 {
            // Never reuse another configured source home's cached content.
            let configuredRoots = roots
            entries = cache.entries.filter { path, _ in configuredRoots.contains { URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix($0.0.path + "/") } }
            pendingPaths = cache.pendingPaths ?? []
        }
    }
    public func snapshot() -> SessionHistorySnapshot {
        ensureLoaded()
        var byID: [String: SessionHistorySession] = [:]
        for entry in entries.values {
            var session = entry.session; session.isFavorite = favorites.contains(session.id)
            if let existing = byID[session.id], existing.isAvailable && (!session.isAvailable || existing.updatedAt >= session.updatedAt) { continue }
            byID[session.id] = session
        }
        return SessionHistorySnapshot(sessions: byID.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }, issues: issues, refreshedAt: refreshedAt)
    }
    public func refresh(rebuild: Bool = false) throws -> SessionHistorySnapshot {
        ensureLoaded()
        let fm = FileManager.default
        issues = []
        var changed = rebuild
        var cacheFailure: Error?
        var discovered = Set<String>()
        var totalBytes = 0
        var pendingCount = 0
        var excludedChildren = 0
        if rebuild { pendingPaths.formUnion(entries.keys) }
        for (root, agent) in roots {
            guard fm.fileExists(atPath: root.path) else { issues.append("Source directory unavailable: \(root.path)"); continue }
            var enumerationErrors = 0
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationErrors += 1; return true }) else {
                issues.append("Unable to enumerate source: \(root.path)"); continue
            }
            for case let file as URL in iterator {
                if agent == .claude, file.lastPathComponent == "subagents" { iterator.skipDescendants(); excludedChildren += 1; continue }
                guard file.pathExtension == "jsonl" else { continue }
                if agent == .claude, file.lastPathComponent.hasPrefix("agent-") { excludedChildren += 1; continue }
                do {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    discovered.insert(file.path)
                    let size = values.fileSize ?? 0
                    let modified = values.contentModificationDate ?? .distantPast
                    if !pendingPaths.contains(file.path), let cached = entries[file.path], cached.modified == modified, cached.size == size, cached.session.isAvailable { continue }
                    if totalBytes > 0 && totalBytes + min(size, SessionHistoryParser.byteLimit) > refreshByteBudget {
                        pendingPaths.insert(file.path)
                        pendingCount += 1
                        continue
                    }
                    totalBytes += min(size, SessionHistoryParser.byteLimit)
                    entries[file.path] = try autoreleasepool {
                        var session = try SessionHistoryParser.read(url: file, agent: agent, updatedAt: modified)
                        do { try save(session, name: contentFilename(file.path)) } catch { cacheFailure = error; throw error }
                        session.messages = []
                        return Entry(modified: modified, size: size, session: session)
                    }
                    pendingPaths.remove(file.path)
                    changed = true
                } catch {
                    issues.append("Unreadable history source: \(file.path)")
                    if var cached = entries[file.path], cached.session.isAvailable { cached.session.isAvailable = false; entries[file.path] = cached; changed = true }
                }
            }
            if enumerationErrors > 0 { issues.append("Partial coverage: \(enumerationErrors) inaccessible paths in \(root.path).") }
        }
        for path in entries.keys where !discovered.contains(path) {
            // Retain a cached transcript for provenance/favorites, but never claim its source is available.
            if entries[path]?.session.isAvailable == true { entries[path]?.session.isAvailable = false; changed = true }
        }
        if excludedChildren > 0 { issues.append("Scope: \(excludedChildren) Claude child-session directories/files excluded from parent history.") }
        if pendingCount > 0 { issues.append("Indexing: \(pendingCount) sources pending; refresh continues the next bounded batch.") }
        refreshedAt = Date()
        indexDirty = indexDirty || changed
        if let cacheFailure { throw cacheFailure }
        if indexDirty {
            try save(Cache(entries: entries, pendingPaths: pendingPaths), name: "index.json")
            indexDirty = false
        }
        return snapshot()
    }
    /// Snapshots retain metadata only; load the selected transcript off the main actor.
    public func session(id: String) throws -> SessionHistorySession? {
        guard let metadata = snapshot().sessions.first(where: { $0.id == id }) else { return nil }
        return try load(metadata)
    }
    private func load(_ metadata: SessionHistorySession) throws -> SessionHistorySession {
        let data = try Data(contentsOf: directory.appendingPathComponent(contentFilename(metadata.sourcePath)))
        var full = try JSONDecoder().decode(SessionHistorySession.self, from: data)
        guard full.id == metadata.id, full.sourcePath == metadata.sourcePath else {
            throw CocoaError(.fileReadCorruptFile)
        }
        full.isFavorite = metadata.isFavorite
        full.isAvailable = metadata.isAvailable && FileManager.default.isReadableFile(atPath: metadata.sourcePath)
        return full
    }
    private func contentFilename(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    public func setFavorite(sessionID: String, isFavorite: Bool) throws {
        ensureLoaded()
        var next = favorites
        if isFavorite { next.insert(sessionID) } else { next.remove(sessionID) }
        try save(next, name: "favorites.json")
        favorites = next
    }
    public func search(_ query: String, projectPath: String? = nil, favoritesOnly: Bool = false, limit: Int = 200) throws -> [SessionHistorySearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var results: [SessionHistorySearchResult] = []
        for session in snapshot().sessions {
            try Task.checkCancellation()
            guard projectPath == nil || session.projectPath == projectPath, !favoritesOnly || session.isFavorite else { continue }
            let reachedLimit = try autoreleasepool {
                let full = try load(session)
                for (index, message) in full.messages.enumerated() {
                    if index.isMultiple(of: 64) { try Task.checkCancellation() }
                    guard let range = message.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                    let start = message.text.index(range.lowerBound, offsetBy: -70, limitedBy: message.text.startIndex) ?? message.text.startIndex
                    let end = message.text.index(range.upperBound, offsetBy: 130, limitedBy: message.text.endIndex) ?? message.text.endIndex
                    results.append(SessionHistorySearchResult(sessionID: session.id, messageID: message.id, excerpt: String(message.text[start..<end])))
                    if results.count >= limit { return true }
                }
                return false
            }
            if reachedLimit { return results }
        }
        return results
    }
    private func save<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
