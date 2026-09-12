import Foundation
import SQLite3
import Testing
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Copilot read-only history")
struct CopilotHistoryTests {
    @Test("WAL updates, empty sessions, bounded dialogue and quiet snapshot round-trip")
    func history() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("session-store.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw CopilotSessionReader.ReadError.unreadable
            }
        }
        try execute("""
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE sessions(id TEXT PRIMARY KEY,cwd TEXT,branch TEXT,summary TEXT,created_at TEXT,updated_at TEXT);
            CREATE TABLE turns(id INTEGER PRIMARY KEY,session_id TEXT,turn_index INTEGER,user_message TEXT,assistant_response TEXT,timestamp TEXT);
            INSERT INTO sessions VALUES('s','/tmp/copilot-project','main',NULL,'2026-09-12 01:00:00','2026-09-12 01:01:00');
            INSERT INTO sessions VALUES('empty','/tmp/empty',NULL,NULL,NULL,NULL);
            INSERT INTO turns VALUES(1,'s',0,'Inspect this project','Initial reply','2026-09-12 01:01:00');
            """)
        let original = try Data(contentsOf: database)
        let store = SessionStore(copilotDatabase: database)
        await store.refreshCopilotHistory()
        let snapshot = await store.snapshot(now: Date())
        let session = try #require(snapshot.sessions.first)
        #expect(snapshot.sessions.count == 1)
        #expect(session.id == "copilot:s")
        #expect(session.name == "Inspect this project")
        #expect(session.branch == "main")
        #expect(session.historyOnly == true)
        #expect(session.presentationState == .idle)
        #expect(!session.hasUnreadCompletion && session.completionID == nil)
        #expect(!SessionActionSupport.resolve(for: session).isAvailable)
        #expect(!session.canJump)
        #expect(ToolActivity.label(for: session) == "History · read only")
        #expect(VoicePrompt.sessionContext([session]).contains("\"status\":\"unknown\""))
        #expect(VoicePrompt.systemPrompt(sessions: [session]).contains("live status unknown"))
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.sessions.first?.historyOnly == true)
        let output = await store.recentOutput(sessionID: session.id)
        #expect(output.entries.map(\.text) == ["Inspect this project", "Initial reply"])
        #expect(try Data(contentsOf: database) == original)
        // Writes stay in WAL; the main database does not change.
        try execute("UPDATE turns SET assistant_response='Changed reply' WHERE id=1")
        await store.refreshCopilotHistory()
        #expect(await store.recentOutput(sessionID: session.id).entries.last?.text == "Changed reply")
        #expect(try Data(contentsOf: database) == original)
        // Reproduce same-size rewrites in one second; Date descriptions lose
        // these fractions, so this locks down the scanner signature regression.
        try execute("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000.1)], ofItemAtPath: database.path)
        await store.refreshCopilotHistory()
        let size = try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? NSNumber
        try execute("UPDATE turns SET assistant_response='Another reply' WHERE id=1")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000.9)], ofItemAtPath: database.path)
        #expect(try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? NSNumber == size)
        await store.refreshCopilotHistory()
        #expect(await store.recentOutput(sessionID: session.id).entries.last?.text == "Another reply")
        for index in 1...8 {
            try execute("INSERT INTO turns VALUES(\(index+1),'s',\(index),'Question \(index)','\(String(repeating: "x", count: 650))',NULL)")
        }
        await store.refreshCopilotHistory()
        let bounded = await store.recentOutput(sessionID: session.id)
        #expect(bounded.truncated && bounded.entries.count == 12)
        #expect(bounded.entries.allSatisfy { $0.text.count <= 600 })
        await store.sweep(now: Date().addingTimeInterval(24*3600))
        #expect(await store.snapshot(now: Date()).sessions.count == 1)
        let server = VibeBuddyServer(store: store, token: "copilot-test-token")
        try await server.buildApplication().test(.live) { client in
            try await client.execute(uri: "/recent-output?sessionId=copilot:s", method: .get,
                headers: [.authorization: "Bearer copilot-test-token"]) { response in
                #expect(response.status == .ok)
                let wire = try JSONDecoder().decode(RecentOutput.self, from: Data(buffer: response.body))
                #expect(wire.entries == bounded.entries)
            }
        }
        try execute("DELETE FROM turns")
        await store.refreshCopilotHistory()
        #expect(await store.snapshot(now: Date()).sessions.isEmpty)
    }

    @Test("Missing store is empty; incompatible schema can recover")
    func recovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("session-store.db")
        var reader = CopilotSessionReader(database: db)
        #expect(try reader.refresh() == [])
        try Data("bad database".utf8).write(to: db)
        #expect(throws: (any Error).self) { try reader.refresh() }
        try FileManager.default.removeItem(at: db)
        #expect(try reader.refresh() == [])
    }
}
