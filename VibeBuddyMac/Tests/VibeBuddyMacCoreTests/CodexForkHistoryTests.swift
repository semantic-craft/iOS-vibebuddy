import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Codex fork history ownership")
struct CodexForkHistoryTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var cache: URL { root.appendingPathComponent("cache") }
        func repository(budget: Int = 1, readOnly: Bool = false) -> SessionHistoryRepository {
            SessionHistoryRepository(claudeHome: root, codexHome: root, cursorHome: root,
                cacheDirectory: cache, refreshByteBudget: budget, readOnly: readOnly)
        }
        func write(_ id: String, fork: Bool = false) throws -> URL {
            let file = root.appendingPathComponent("sessions/\(id).jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = [#"{"type":"session_meta","payload":{"id":"OWNER","cwd":"/owner","originator":"Codex Desktop","source":"vscode"}}"#.replacingOccurrences(of: "OWNER", with: id)]
            if fork {
                lines.append(#"{"type":"session_meta","payload":{"id":"parent","cwd":"/ancestor","source":{"subagent":"spawn"}}}"#)
                lines.append(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"inheritedneedle"}]}}"#)
            }
            lines.append(#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OWNERneedle"}]}}"#.replacingOccurrences(of: "OWNER", with: id))
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        /// Recreate v7's last-metadata-wins metadata and content cache, leaving
        /// original source bytes/revisions and the path-keyed FTS rows intact.
        func legacyIndex() throws {
            for file in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                guard var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { continue }
                func legacy(_ session: inout [String: Any]) {
                    if (session["sourcePath"] as? String)?.hasSuffix("child.jsonl") == true {
                        session["id"] = "codex:parent"; session["nativeSessionID"] = "parent"
                        session["projectPath"] = "/ancestor"; session["source"] = "subagent"
                    }
                }
                if file.lastPathComponent == "index.json", var entries = value["entries"] as? [String: [String: Any]] {
                    value["version"] = 7
                    for path in entries.keys {
                        var entry = entries[path]!
                        entry.removeValue(forKey: "codexIdentityVersion")
                        var session = entry["session"] as! [String: Any]
                        legacy(&session); entry["session"] = session; entries[path] = entry
                    }
                    value["entries"] = entries
                } else if value["messages"] != nil { legacy(&value) }
                try JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
            }
        }
    }

    @Test func firstEnvelopeOwnsIdentityAndProvenance() throws {
        let f = Fixture(); defer { f.remove() }
        let file = try f.write("child", fork: true)
        let session = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        #expect(session.id == "codex:child")
        #expect(session.projectPath == "/owner" && session.source == "desktop")
        #expect(session.messages.contains { $0.text == "inheritedneedle" })
        #expect(session.warnings.contains { $0.contains("parent") })
    }

    @Test(arguments: [false, true])
    func boundedLegacyMigrationPreservesMarksAndSearch(changedPaths: Bool) async throws {
        let f = Fixture(); defer { f.remove() }
        let parent = try f.write("parent")
        let child = try f.write("child", fork: true)
        let originals = try [Data(contentsOf: parent), Data(contentsOf: child)]
        let seed = f.repository(budget: 1_000_000)
        _ = try await seed.refresh()
        try await seed.setFavorite(sessionID: "codex:parent", isFavorite: true)
        try await seed.setPinned(sessionID: "codex:parent", isPinned: true)
        try await seed.setArchived(sessionID: "codex:parent", isArchived: true)
        let summary = SessionHistorySummary(sessionID: "codex:parent", sourcePath: parent.path,
            sourceRevision: nil, text: "saved user summary", provider: "test", model: "test", generatedAt: Date(), coverage: "all")
        try await seed.saveSummary(summary)
        try f.legacyIndex()
        let markFiles = try FileManager.default.contentsOfDirectory(at: f.cache, includingPropertiesForKeys: nil)
            .filter { ["favorites.json", "pins.json", "archives.json"].contains($0.lastPathComponent) || $0.lastPathComponent.hasPrefix("summary-") }
        let markBytes = try markFiles.map { try Data(contentsOf: $0) }
        let reader = f.repository(readOnly: true)
        #expect(await reader.snapshot().sessions.isEmpty) // Never expose known wrong identities.
        #expect(try await reader.readTranscript(key: "codex:child").session.id == "codex:child")
        #expect(try await reader.search("childneedle").isEmpty)
        let writer = f.repository()
        let partial = try await (changedPaths ? writer.refresh(changedPaths: []) : writer.refresh())
        #expect(partial.pendingSourceCount == 1)
        #expect(partial.sessions.count == 1)
        // Restart between batches proves migration state survives v8 publication.
        let next = f.repository()
        let done = try await (changedPaths ? next.refresh(changedPaths: []) : next.refresh())
        #expect(done.pendingSourceCount == 0)
        #expect(Set(done.sessions.map(\.id)) == ["codex:parent", "codex:child"])
        let owner = try #require(done.sessions.first { $0.id == "codex:parent" })
        #expect(owner.isFavorite && owner.isPinned == true && owner.archivedLocally == true)
        #expect(done.sessions.first { $0.id == "codex:child" }?.isFavorite == false)
        for id in ["parent", "child"] {
            #expect(try await next.readTranscript(key: "codex:" + id).session.nativeSessionID == id)
            let hits = try await next.search(id + "needle", sessionIDs: ["codex:parent", "codex:child"])
            #expect(hits.hits.map(\.session.id) == ["codex:" + id])
            #expect(hits.notIndexed.isEmpty && hits.unavailable.isEmpty)
        }
        #expect(try markFiles.map { try Data(contentsOf: $0) } == markBytes)
        #expect(try [Data(contentsOf: parent), Data(contentsOf: child)] == originals)
        try await reader.reloadReadOnlyMetadata()
        #expect(await reader.snapshot().sessions.count == 2)
        // Genuine duplicate owner sources must remain ambiguous after repair.
        let duplicate = parent.deletingLastPathComponent().appendingPathComponent("duplicate.jsonl")
        try Data(contentsOf: parent).write(to: duplicate)
        _ = try await next.refresh(changedPaths: [duplicate.path])
        do {
            _ = try await next.readTranscript(key: "codex:parent")
            Issue.record("Duplicate owner was silently selected")
        } catch { #expect(String(describing: error).contains("Ambiguous session key")) }
    }

    @Test func unavailableLegacySourceRemainsRetainedAndRecovers() async throws {
        let f = Fixture(); defer { f.remove() }
        let child = try f.write("child", fork: true)
        let seed = f.repository()
        _ = try await seed.refresh()
        try await seed.setFavorite(sessionID: "codex:parent", isFavorite: true)
        try f.legacyIndex()
        let original = try Data(contentsOf: child)
        let favorite = try Data(contentsOf: f.cache.appendingPathComponent("favorites.json"))
        try FileManager.default.removeItem(at: child)
        let missing = try await f.repository().refresh(changedPaths: [])
        #expect(missing.sessions.isEmpty && missing.pendingSourceCount == 0)
        #expect(missing.issues.contains { $0.contains("identity migration") })
        let index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.cache.appendingPathComponent("index.json"))) as? [String: Any])
        #expect((index["entries"] as? [String: Any])?.count == 1)
        try original.write(to: child)
        let restored = try await f.repository().refresh(changedPaths: [child.path])
        #expect(restored.sessions.map(\.id) == ["codex:child"])
        #expect(try Data(contentsOf: f.cache.appendingPathComponent("favorites.json")) == favorite)
    }

    @Test func phoneAndMacReadParentAndChildSeparately() async throws {
        let f = Fixture(); defer { f.remove() }
        _ = try f.write("parent"); _ = try f.write("child", fork: true)
        let http = HistoryHTTPReader(repository: { f.repository(readOnly: true) })
        for id in ["parent", "child"] {
            let key = "codex:" + id
            let mac = try await f.repository(readOnly: true).readTranscript(key: key)
            let response = await http.read(uri: "/history?sourceID=mac&key=" + key, sourceID: "mac")
            #expect(response.status == 200)
            let page = try JSONDecoder().decode(HistoryPage.self, from: response.data)
            #expect(page.key == key)
            #expect(page.messages.map(\.text) == mac.session.messages.map(\.text))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_FORK_FIXTURES"] != nil))
    func realCopiesUseMacRepositoryAndSearch() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VIBEBUDDY_FORK_FIXTURES"]))
        let f = Fixture(); defer { f.remove() }
        let sessions = f.root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var owners: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
            let data = try Data(contentsOf: file)
            let first = try #require(data.split(separator: 10).first)
            let root = try #require(JSONSerialization.jsonObject(with: Data(first)) as? [String: Any])
            let payload = try #require(root["payload"] as? [String: Any])
            let owner = try #require(payload["id"] as? String)
            owners.append(owner)
            let copy = sessions.appendingPathComponent(file.lastPathComponent)
            try data.write(to: copy)
            var parser = CodexRolloutParser()
            var lastCompletion: (turn: String, text: String)?
            var emittedOwners = Set<String>()
            for line in data.split(separator: 10) {
                for event in parser.parseEvents(Data(line), receivedAt: Date()) {
                    emittedOwners.insert(event.sessionID)
                }
                if let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   row["type"] as? String == "event_msg", let event = row["payload"] as? [String: Any],
                   event["type"] as? String == "task_complete", let turn = event["turn_id"] as? String,
                   let text = event["last_agent_message"] as? String { lastCompletion = (turn, text) }
            }
            #expect(parser.sessionID == owner)
            let subagent = payload["thread_source"] as? String == "subagent"
            #expect(subagent ? emittedOwners.isEmpty : emittedOwners == [owner])
            let completion = try #require(lastCompletion)
            let result = CodexCompletionReader.read(path: copy.path, sessionID: owner, turnID: completion.turn)
            if data.split(separator: 10).contains(where: { $0.count > 2 * 1024 * 1024 }) {
                // Preserve the completion reader's existing per-record safety limit.
                // This is an explicit completion gap, not a history identity failure.
                #expect(throws: CodexCompletionReader.Failure.readLimitExceeded) { try result.get() }
                print("Real completion NOT covered owner=\(owner): source contains a record above the existing 2 MiB limit")
            } else {
                let recovered = try result.get()
                #expect(recovered.text == completion.text)
                print("Real fork completion owner=\(owner) turn=\(completion.turn) chars=\(recovered.text.count) subagent=\(subagent)")
            }
        }
        #expect(owners.count == 2)
        let repository = f.repository(budget: 64 * 1024 * 1024)
        let snapshot = try await repository.refresh()
        #expect(Set(snapshot.sessions.map(\.nativeSessionID)) == Set(owners))
        for id in owners {
            // This is SessionReaderModel's exact readTranscript(key:) entry point.
            let transcript = try await repository.readTranscript(key: "codex:" + id)
            #expect(transcript.session.nativeSessionID == id)
            #expect(!transcript.session.messages.isEmpty)
            let text = try #require(transcript.session.messages.last { $0.kind == .text && $0.text.count > 16 }?.text)
            let page = try await repository.search(String(text.prefix(16)), sessionIDs: ["codex:" + id])
            #expect(!page.hits.isEmpty)
            #expect(page.hits.allSatisfy { $0.session.nativeSessionID == id })
            print("Real fork copy owner=\(id) records=\(transcript.session.messages.count) searchHits=\(page.hits.count)")
        }
    }

}
