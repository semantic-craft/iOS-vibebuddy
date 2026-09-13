import Foundation
import CryptoKit
import Darwin

/// Local history is a read-only projection, independent of the live Session reducer.
public actor SessionHistoryRepository {
    private struct Entry: Codable { var modified: Date; var size: Int; var session: SessionHistorySession }
    private struct Cache: Codable { var version: Int = 7; var entries: [String: Entry]; var pendingPaths: Set<String>? = nil }
    private let roots: [(URL, SessionHistoryAgent)]
    private let directory: URL
    private let grokHome: URL?
    private let refreshByteBudget: Int
    private var entries: [String: Entry] = [:]
    private var favorites = Set<String>()
    private var pins = Set<String>()
    private var archives = Set<String>()
    private var issues: [String] = []
    private var refreshedAt: Date?
    private var pendingPaths = Set<String>()
    private var loaded = false
    private var indexDirty = false
    private let readOnly: Bool
    private var transcriptSlot: (path: String, revision: String, transcript: HistoryTranscript)?
    private var usableIndex = false
    public init(claudeHome: URL? = nil, codexHome: URL? = nil, grokHome: URL? = nil, cacheDirectory: URL? = nil, refreshByteBudget: Int = 256 * 1024 * 1024, readOnly: Bool = false) {
        self.readOnly = readOnly
        self.grokHome = grokHome?.resolvingSymlinksInPath()
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
        if let data = try? Data(contentsOf: directory.appendingPathComponent("archives.json")), let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) { archives = decoded }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("pins.json")), let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) { pins = decoded }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("favorites.json")), let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) { favorites = decoded }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")), let cache = try? JSONDecoder().decode(Cache.self, from: data), [4, 5, 6, 7].contains(cache.version) {
            usableIndex = true
            // Never reuse another configured source home's cached content.
            // A removed leaf cannot resolve symlinks. Keep both spellings of
            // existing configured roots so /private/var caches survive deletion.
            let prefixes = roots.flatMap { root, _ -> [String] in
                var paths = [root.path + "/"]
                if let physical = realpath(root.path, nil) {
                    paths.append(String(cString: physical) + "/")
                    free(physical)
                }
                return paths
            }
            func belongsToRoots(_ path: String) -> Bool {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                return prefixes.contains { path.hasPrefix($0) || resolved.hasPrefix($0) }
            }
            let grokPrefix = grokHome?.appendingPathComponent("sessions").resolvingSymlinksInPath().path.appending("/")
            entries = cache.entries.filter { path, entry in
                belongsToRoots(path) || (entry.session.agent == .grokBuild && grokPrefix.map { path.hasPrefix($0) } == true)
            }
            pendingPaths = Set((cache.pendingPaths ?? []).filter(belongsToRoots))
            if cache.version < 7 { pendingPaths.formUnion(entries.filter { $0.value.session.agent.supportsTranscript }.keys) }
        }
    }
    public func hasUsableIndex() -> Bool { ensureLoaded(); return usableIndex }

    public func snapshot() -> SessionHistorySnapshot {
        ensureLoaded()
        var byID: [String: SessionHistorySession] = [:]
        for entry in entries.values {
            var session = entry.session; session.isFavorite = favorites.contains(session.id); session.isPinned = pins.contains(session.id); session.archivedLocally = archives.contains(session.id)
            if session.agent.supportsTranscript { session.sourceRevision = "\(entry.modified.timeIntervalSince1970)|\(entry.size)" }
            if let existing = byID[session.id] {
                if existing.isAvailable != session.isAvailable {
                    if existing.isAvailable { continue }
                } else if existing.updatedAt > session.updatedAt ||
                    (existing.updatedAt == session.updatedAt && existing.sourcePath < session.sourcePath) { continue }
            }
            byID[session.id] = session
        }
        return SessionHistorySnapshot(sessions: byID.values.sorted { if ($0.isPinned == true) != ($1.isPinned == true) { return $0.isPinned == true }; return $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }, issues: issues, refreshedAt: refreshedAt, pendingSourceCount: pendingPaths.count)
    }
    public func refresh(rebuild: Bool = false) throws -> SessionHistorySnapshot {
        guard !readOnly else { throw HistoryToolError.readOnly }
        let lock: HistoryRefreshLock
        do { lock = try HistoryRefreshLock(directory: directory) }
        catch HistoryToolError.refreshBusy {
            issues = ["another refresh is running; skipped this refresh."]
            return snapshot()
        }
        defer { withExtendedLifetime(lock) {} }
        return try refreshLocked(rebuild: rebuild)
    }

    /// Explicit CLI maintenance, never exposed as an MCP tool. A nil result means
    /// an existing usable index was left alone; contention always throws.
    public func index(rebuild: Bool = false) throws -> SessionHistorySnapshot? {
        guard !readOnly else { throw HistoryToolError.readOnly }
        let lock = try HistoryRefreshLock(directory: directory)
        defer { withExtendedLifetime(lock) {} }
        reloadForRefresh()
        if usableIndex && !rebuild { return nil }
        return try refreshLocked(rebuild: rebuild, full: true)
    }

    private func reloadForRefresh() {
        // Another writer may have advanced a bounded batch since this actor last ran.
        loaded = false
        entries = [:]; pendingPaths = []; usableIndex = false
        ensureLoaded()
    }

    private func refreshLocked(rebuild: Bool, full: Bool = false) throws -> SessionHistorySnapshot {
        reloadForRefresh()
        let fm = FileManager.default
        issues = []
        var changed = rebuild || !usableIndex
        var cacheFailure: Error?
        var discovered = Set<String>()
        var totalBytes = 0
        var pendingCount = 0
        var excludedChildren = 0
        // Rebuild into a private database then rename it atomically. Readers with
        // an open connection finish on the previous complete database; corrupt
        // derived databases can be replaced without deleting a reader's inode.
        let staging = rebuild ? directory.appendingPathComponent(".rebuild-" + UUID().uuidString) : nil
        defer { if let staging { try? fm.removeItem(at: staging) } }
        let searchIndex = try SessionHistorySearchIndex(directory: staging ?? directory)
        if rebuild { pendingPaths.formUnion(entries.filter { $0.value.session.agent.supportsTranscript }.keys) }
        for (root, agent) in roots {
            guard fm.fileExists(atPath: root.path) else { issues.append("Source directory unavailable: \(root.path)"); continue }
            var enumerationErrors = 0
            var seenPaths = Set<String>()
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationErrors += 1; return true }) else {
                issues.append("Unable to enumerate source: \(root.path)"); continue
            }
            for case let file as URL in iterator {
                if agent == .claude, file.lastPathComponent == "subagents" { iterator.skipDescendants(); excludedChildren += 1; continue }
                guard file.pathExtension == "jsonl" else { continue }
                if agent == .claude, file.lastPathComponent.hasPrefix("agent-") { excludedChildren += 1; continue }
                seenPaths.insert(file.path)
                do {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    discovered.insert(file.path)
                    let size = values.fileSize ?? 0
                    let modified = values.contentModificationDate ?? .distantPast
                    if !pendingPaths.contains(file.path), let cached = entries[file.path], cached.modified == modified, cached.size == size, cached.session.isAvailable { continue }
                    if !full && totalBytes > 0 && totalBytes + min(size, SessionHistoryParser.byteLimit) > refreshByteBudget {
                        pendingPaths.insert(file.path)
                        pendingCount += 1
                        continue
                    }
                    totalBytes += min(size, SessionHistoryParser.byteLimit)
                    var session = try autoreleasepool {
                        try SessionHistoryParser.read(url: file, agent: agent, updatedAt: modified)
                    }
                    session.sourceArchived = agent == .codex && root.lastPathComponent == "archived_sessions"
                    let revision = "\(modified.timeIntervalSince1970)|\(size)"
                    session.sourceRevision = revision
                    do {
                        try save(session, name: contentFilename(file.path))
                        try searchIndex.replace(session, stamp: "v7|" + revision)
                    } catch { cacheFailure = error; throw error }
                    session.messages = []
                    entries[file.path] = Entry(modified: modified, size: size, session: session)
                    pendingPaths.remove(file.path)
                    changed = true
                } catch {
                    issues.append("Unreadable history source: \(file.path)")
                    if var cached = entries[file.path], cached.session.isAvailable { cached.session.isAvailable = false; entries[file.path] = cached; changed = true }
                }
            }
            if enumerationErrors > 0 { issues.append("Partial coverage: \(enumerationErrors) inaccessible paths in \(root.path).") }
            else {
                // A complete enumeration can retire deferred sources that disappeared.
                // Unavailable/partial roots retain them so omissions stay visible.
                var prefixes = [root.path + "/"]
                // Foundation may shorten /private/var while enumeration returns its
                // physical spelling. Resolve the existing root, not a deleted leaf.
                if let physical = realpath(root.path, nil) {
                    prefixes.append(String(cString: physical) + "/")
                    free(physical)
                }
                let removed = pendingPaths.filter { path in
                    prefixes.contains { path.hasPrefix($0) } && !seenPaths.contains(path)
                }
                if !removed.isEmpty { pendingPaths.subtract(removed); changed = true }
            }
        }
        if let grokHome {
            let inventory = GrokHistorySource.scan(home: grokHome)
            issues += inventory.issues
            if !inventory.sessions.isEmpty { issues.append(GrokHistorySource.coverage) }
            for session in inventory.sessions {
                discovered.insert(session.sourcePath)
                pendingPaths.remove(session.sourcePath)
                if entries[session.sourcePath]?.session != session {
                    entries[session.sourcePath] = Entry(modified: session.updatedAt, size: 0, session: session)
                    changed = true
                }
            }
        }
        for path in entries.keys where !discovered.contains(path) {
            // Retain a cached transcript for provenance/favorites, but never claim its source is available.
            if entries[path]?.session.isAvailable == true { entries[path]?.session.isAvailable = false; changed = true }
        }
        if excludedChildren > 0 { issues.append("Scope: \(excludedChildren) Claude child-session directories/files excluded from parent history.") }
        if pendingCount > 0 { issues.append("Indexing: \(pendingCount) sources pending; refresh continues the next bounded batch.") }
        if let cacheFailure { throw cacheFailure }
        // Migrate old lazy indexes and repair missing FTS rows only while holding
        // the writer lock. No query ever decodes caches or writes SQLite rows.
        for entry in entries.values where entry.session.agent.supportsTranscript {
            let stamp = "v7|\(entry.modified.timeIntervalSince1970)|\(entry.size)"
            if try !searchIndex.isCurrent(path: entry.session.sourcePath, stamp: stamp) {
                let session = try autoreleasepool { try load(entry.session) }
                let revision = "\(entry.modified.timeIntervalSince1970)|\(entry.size)"
                if let cachedRevision = session.sourceRevision, cachedRevision != revision {
                    issues.append("Not indexed yet: cache revision differs from metadata for \(entry.session.sourcePath).")
                    continue
                }
                try searchIndex.replace(session, stamp: stamp)
            }
        }
        if let staging {
            guard rename(staging.appendingPathComponent("search.sqlite").path,
                         directory.appendingPathComponent("search.sqlite").path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        refreshedAt = Date()
        indexDirty = indexDirty || changed
        if indexDirty {
            try save(Cache(entries: entries, pendingPaths: pendingPaths), name: "index.json")
            indexDirty = false
            usableIndex = true
        }
        return snapshot()
    }
    /// Prefer an available source over retained unavailable paths, as snapshot does.
    /// Multiple eligible files remain ambiguous; callers must not guess an identity.
    public func resolveIndexedSession(key: String) throws -> SessionHistorySession? {
        let reference = try HistorySessionReference(key)
        ensureLoaded()
        let candidates = entries.values.filter { $0.session.agent == reference.agent && $0.session.nativeSessionID == reference.nativeID }
        let available = candidates.filter { $0.session.isAvailable }
        let matches = available.isEmpty ? candidates : available
        guard matches.count <= 1 else { throw HistoryToolError.executionFailed("Ambiguous session key: multiple source files.") }
        guard let entry = matches.first else { return nil }
        var session = entry.session
        if session.agent.supportsTranscript { session.sourceRevision = "\(entry.modified.timeIntervalSince1970)|\(entry.size)" }
        session.isFavorite = favorites.contains(session.id)
        session.isPinned = pins.contains(session.id)
        session.archivedLocally = archives.contains(session.id)
        return session
    }

    /// Bounded read-only access; never refreshes or publishes a cache.
    public func readTranscript(key: String) throws -> HistoryTranscript {
        let reference = try HistorySessionReference(key)
        var metadata = try resolveIndexedSession(key: reference.key)
        let indexed = metadata?.sourceRevision
        if reference.agent == .grokBuild {
            guard let metadata else { throw HistoryToolError.executionFailed("Unknown session key.") }
            return HistoryTranscript(session: metadata, provenance: "official list metadata, no transcript")
        }
        if metadata == nil {
            // Locate by native filename only; never parse every conversation to find one ID.
            var candidates: [URL] = []
            for (root, agent) in roots where agent == reference.agent {
                guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in iterator {
                    if file.lastPathComponent == "subagents" { iterator.skipDescendants(); continue }
                    let stem = file.deletingPathExtension().lastPathComponent
                    guard file.pathExtension == "jsonl", !stem.hasPrefix("agent-"),
                          stem == reference.nativeID || (agent == .codex && stem.hasSuffix("-" + reference.nativeID)),
                          file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                          let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                          values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    candidates.append(file)
                }
            }
            guard candidates.count == 1 else { throw HistoryToolError.executionFailed(candidates.isEmpty ? "Unknown session key." : "Ambiguous session key: multiple source files.") }
            let file = candidates[0]
            metadata = SessionHistorySession(id: "", nativeSessionID: reference.nativeID, agent: reference.agent, projectPath: "", title: "", sourcePath: file.path, updatedAt: .distantPast, messages: [])
        }
        guard let metadata else { throw HistoryToolError.executionFailed("Unknown session key.") }
        let file = URL(fileURLWithPath: metadata.sourcePath)
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let modified = values?.contentModificationDate
        let size = values?.fileSize
        let current = modified.flatMap { date in size.map { "\(date.timeIntervalSince1970)|\($0)" } }
        if let current, let slot = transcriptSlot, slot.path == file.path, slot.revision == current { return slot.transcript }
        if var cached = verifiedCache(metadata, indexedRevision: indexed),
           current == nil || current == cached.sourceRevision {
            cached.isAvailable = current != nil && FileManager.default.isReadableFile(atPath: file.path)
            let result = HistoryTranscript(session: cached, provenance: "cache")
            if let current { transcriptSlot = (file.path, current, result) }
            return result
        }
        guard let modified, let current else { throw HistoryToolError.executionFailed("Source unavailable and no verifiable transcript cache.") }
        var session = try SessionHistoryParser.read(url: file, agent: reference.agent, updatedAt: modified)
        let after = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard after.contentModificationDate == modified, after.fileSize == size else { throw HistoryToolError.executionFailed("Source changed while reading; retry for a consistent revision.") }
        guard session.nativeSessionID == reference.nativeID else { throw HistoryToolError.executionFailed("Source identity does not match the requested key.") }
        session.sourceRevision = current
        let result = HistoryTranscript(session: session, provenance: "source, index stale")
        transcriptSlot = (file.path, current, result)
        return result
    }

    /// Legacy caches have no embedded revision. They are usable only when
    /// published no later than index.json; otherwise a refresh may have replaced
    /// the cache while metadata/FTS still describe the previous generation.
    private func verifiedCache(_ metadata: SessionHistorySession, indexedRevision: String?) -> SessionHistorySession? {
        let cacheURL = directory.appendingPathComponent(contentFilename(metadata.sourcePath))
        guard let data = try? Data(contentsOf: cacheURL),
              var cached = try? JSONDecoder().decode(SessionHistorySession.self, from: data),
              cached.sourcePath == metadata.sourcePath, cached.agent == metadata.agent,
              cached.nativeSessionID == metadata.nativeSessionID else { return nil }
        let cacheTime = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let indexTime = (try? directory.appendingPathComponent("index.json").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let legacyPublished = cacheTime.flatMap { cache in indexTime.map { cache <= $0 } } == true
        guard let revision = cached.sourceRevision ?? (legacyPublished ? indexedRevision : nil),
              revision == indexedRevision else { return nil }
        cached.sourceRevision = revision
        return cached
    }

    /// Snapshots retain metadata only; load the selected transcript off the main actor.
    public func session(id: String) throws -> SessionHistorySession? {
        guard let metadata = snapshot().sessions.first(where: { $0.id == id }) else { return nil }
        return try load(metadata)
    }
    private func load(_ metadata: SessionHistorySession) throws -> SessionHistorySession {
        if !metadata.agent.supportsTranscript { return metadata }
        let data = try Data(contentsOf: directory.appendingPathComponent(contentFilename(metadata.sourcePath)))
        var full = try JSONDecoder().decode(SessionHistorySession.self, from: data)
        guard full.id == metadata.id, full.sourcePath == metadata.sourcePath else {
            throw CocoaError(.fileReadCorruptFile)
        }
        full.sourceRevision = full.sourceRevision ?? metadata.sourceRevision
        full.archivedLocally = metadata.archivedLocally
        full.isPinned = metadata.isPinned
        full.sourceArchived = metadata.sourceArchived
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
    /// Library organization only: does not change native archive state or live tasks.
    public func setArchived(sessionID: String, isArchived: Bool) throws {
        ensureLoaded()
        var next = archives
        if isArchived { next.insert(sessionID) } else { next.remove(sessionID) }
        try save(next, name: "archives.json")
        archives = next
    }
    public func setPinned(sessionID: String, isPinned: Bool) throws {
        ensureLoaded()
        var next = pins
        if isPinned { next.insert(sessionID) } else { next.remove(sessionID) }
        try save(next, name: "pins.json")
        pins = next
    }
    public func search(_ query: String, projectPath: String? = nil, favoritesOnly: Bool = false,
                       agent: SessionHistoryAgent? = nil, archived: Bool? = nil,
                       limit: Int = 200) throws -> [SessionHistorySearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let sessions = snapshot().sessions.filter {
            $0.agent.supportsTranscript && (projectPath == nil || $0.projectPath == projectPath) && (!favoritesOnly || $0.isFavorite)
                && (agent == nil || $0.agent == agent) && (archived == nil || $0.isArchived == archived)
        }
        guard !sessions.isEmpty else { return [] }
        let searchIndex = try SessionHistorySearchIndex(directory: directory, readOnly: true)
        return try searchIndex.search(needle, sessions: sessions, limit: limit)
    }
    /// Reference-bearing search shares the App's raw FTS path, but accepts only
    /// hits whose cached dialogue projection and source revision can be verified.
    /// No source discovery, transcript reparsing or store writes happen here.
    public func search(_ query: String, sessionIDs: Set<String>, limit: Int = 200) throws -> HistorySearchPage {
        let sessions = snapshot().sessions.filter { $0.agent.supportsTranscript && sessionIDs.contains($0.id) }
        guard !sessions.isEmpty else { return HistorySearchPage(hits: [], notIndexed: [], unavailable: []) }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("search.sqlite").path) else {
            return HistorySearchPage(hits: [], notIndexed: sessions, unavailable: [])
        }
        var notIndexed: [SessionHistorySession] = []
        let current = sessions.filter { session in
            let values = try? URL(fileURLWithPath: session.sourcePath).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let modified = values?.contentModificationDate, let size = values?.fileSize,
               session.sourceRevision != "\(modified.timeIntervalSince1970)|\(size)" {
                notIndexed.append(session)
                return false
            }
            return true // An unavailable source may still have a verifiable retained cache.
        }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var sequences: [String: [String: Int]] = [:]
        var unavailable = Set<String>()
        var hits: [HistorySearchHit] = []
        let searchIndex = try SessionHistorySearchIndex(directory: directory, readOnly: true)
        let page = try searchIndex.page(query, sessions: current, limit: limit) { hit in
            guard let metadata = byID[hit.sessionID], !unavailable.contains(metadata.id) else { return false }
            if sequences[metadata.id] == nil {
                // Decode only candidates, retaining their small ID mapping instead
                // of keeping every full transcript in memory for the whole search.
                guard let canonical = try? resolveIndexedSession(key: HistoryTools.key(metadata)),
                      canonical.sourcePath == metadata.sourcePath, canonical.sourceRevision == metadata.sourceRevision,
                      let full = verifiedCache(metadata, indexedRevision: metadata.sourceRevision), full.id == metadata.id,
                      (try? HistorySessionReference(HistoryTools.key(metadata))) != nil else {
                    unavailable.insert(metadata.id)
                    return false
                }
                let transcript = HistoryTranscript(session: full, provenance: "cache")
                var mapping: [String: Int] = [:]
                for message in full.messages where message.kind != .meta && message.kind != .thinking {
                    if let seq = transcript.seq(messageID: message.id) { mapping[message.id] = seq }
                }
                sequences[metadata.id] = mapping
            }
            guard let seq = sequences[metadata.id]?[hit.messageID] else { return false }
            hits.append(HistorySearchHit(session: metadata, seq: seq, excerpt: hit.excerpt))
            return true
        }
        notIndexed += page.notIndexed
        return HistorySearchPage(hits: hits, notIndexed: notIndexed, unavailable: current.filter { unavailable.contains($0.id) })
    }

    public func summary(sessionID: String) throws -> SessionHistorySummary? {
        let file = directory.appendingPathComponent("summary-" + contentFilename(sessionID))
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(SessionHistorySummary.self, from: Data(contentsOf: file))
        guard record.sessionID == sessionID else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }
    public func saveSummary(_ summary: SessionHistorySummary) throws {
        try save(summary, name: "summary-" + contentFilename(summary.sessionID))
    }
    private func save<T: Encodable>(_ value: T, name: String) throws {
        guard !readOnly else { throw HistoryToolError.readOnly }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
