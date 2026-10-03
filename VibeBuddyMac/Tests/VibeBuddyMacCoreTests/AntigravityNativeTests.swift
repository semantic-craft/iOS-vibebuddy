import Foundation
import Testing
import SQLite3
@testable import VibeBuddyMacCore
import VibeBuddyKit

struct AntigravityNativeTests {
    @Test func modernHooksOnlyFullyIdleStopEndsTurn() throws {
        let data = Data(#"{"event":"Stop","conversationId":"native-id","workspacePaths":["/work"],"fullyIdle":false,"terminationReason":"NO_TOOL_CALL"}"#.utf8)
        #expect(AntigravityParser.parse(data, receivedAt: Date()) == nil)
        let stopped = Data(#"{"event":"Stop","conversationId":"native-id","workspacePaths":["/work"],"fullyIdle":true,"terminationReason":"USER_CANCELED"}"#.utf8)
        let event = try #require(AntigravityParser.parse(stopped, receivedAt: Date()))
        #expect(event.sessionID == "native-id")
        #expect(event.userStopped)
        #expect(event.completionSucceeded == false)
    }
    @Test func nativeWaitingAndCancellationOverrideDoneTranscriptRows() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".gemini/antigravity-cli")
        let logs = root.appendingPathComponent("brain/native/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("transcript_full.jsonl")
        try Data().write(to: file)
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("conversations/native.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) throws { #expect(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK) }
        try sql("PRAGMA journal_mode=WAL; CREATE TABLE trajectory_meta(cascade_id TEXT); INSERT INTO trajectory_meta VALUES('native'); CREATE TABLE steps(idx INTEGER, step_type INTEGER,status INTEGER); CREATE TABLE executor_metadata(idx INTEGER,data BLOB);")
        let store = SessionStore()
        let monitor = AntigravityCLIMonitor(home: home)
        await monitor.poll(store: store, now: Date())
        let rows = #"{"step_index":0,"type":"USER_INPUT","status":"DONE","content":"choose"}"# + "\n" + #"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"ask_question","args":{"questions":[{"question":"Alpha or Beta?"}]}}]}"# + "\n"
        try Data(rows.utf8).write(to: file)
        try sql("INSERT INTO steps VALUES(0,14,3),(1,15,3),(2,132,9)")
        await monitor.poll(store: store, now: Date())
        let waiting = await store.snapshot(now: Date()).sessions.first { $0.id == "native" }
        #expect(waiting?.status == .needsResponse)
        #expect(waiting?.waitKind == .question)
        #expect(waiting?.controlChannel == ControlChannel.none)
        // User cancellation leaves the transcript on the unanswered planner row.
        try sql("UPDATE steps SET status=6 WHERE idx=2; INSERT INTO executor_metadata VALUES(0,X'08021802')")
        await monitor.poll(store: store, now: Date())
        let cancelled = await store.snapshot(now: Date()).sessions.first { $0.id == "native" }
        #expect(cancelled?.status == .done)
        #expect(cancelled?.hasUnreadCompletion != true)
        #expect(cancelled?.waitKind == nil)
        let resumed = rows + #"{"step_index":3,"type":"USER_INPUT","status":"DONE","content":"finish"}"# + "\n"
        try Data(resumed.utf8).write(to: file)
        try sql("INSERT INTO steps VALUES(3,14,3)")
        await monitor.poll(store: store, now: Date())
        let finished = resumed + #"{"step_index":4,"type":"PLANNER_RESPONSE","status":"DONE","content":"The complete native result."}"# + "\n"
        try Data(finished.utf8).write(to: file)
        try sql("INSERT INTO steps VALUES(4,15,3); UPDATE executor_metadata SET data=X'08041804'")
        await monitor.poll(store: store, now: Date())
        let body = await store.completionBody(sessionID: "native", completionID: "antigravity-cli-3-4")
        #expect(body.text == "The complete native result.")
        let restoredStore = SessionStore()
        let restoredMonitor = AntigravityCLIMonitor(home: home)
        await restoredMonitor.poll(store: restoredStore, now: Date())
        try sql("PRAGMA user_version=2")
        await restoredMonitor.poll(store: restoredStore, now: Date())
        let history = await restoredStore.snapshot(now: Date()).sessions.first { $0.id == "native" }
        #expect(history?.historyOnly == true)
        #expect(history?.completionID == nil)
        #expect(history?.hasUnreadCompletion != true)
    }

    @Test func fullTranscriptIsReadByNativeIdentityWithoutShortExcerpt() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let logs = home.appendingPathComponent("antigravity-cli/brain/native/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let text = String(repeating: "Complete native result.\n", count: 500)
        let row: [String: Any] = ["step_index": 1, "type": "PLANNER_RESPONSE", "status": "DONE", "content": text]
        try JSONSerialization.data(withJSONObject: row).write(to: logs.appendingPathComponent("transcript_full.jsonl"))
        try Data(#"{"type":"PLANNER_RESPONSE","content":"short excerpt"}"#.utf8).write(to: logs.appendingPathComponent("transcript.jsonl"))
        let reader = SessionTranscriptReader(antigravityHome: home)
        let result = try await reader.readTranscript(key: "antigravity:native")
        #expect(result.session.messages.last?.text == text)
        #expect(result.session.nativeSessionID == "native")
    }

    @Test func longNativeCompletionSurvivesResultLedger() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let store = SessionStore(sourceID: "source", journalURL: directory.appendingPathComponent("journal.json"))
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "long", agent: .antigravity,
            observationSource: .transcript, timestamp: now))
        let text = String(repeating: "Original complete result line.\n", count: 800)
        await store.ingest(HookEvent(kind: .stop, sessionID: "long", agent: .antigravity,
            observationSource: .transcript, timestamp: now.addingTimeInterval(0.1),
            completionText: text, completionSucceeded: true, sourceCompletionID: "native-end"))
        let body = await store.completionBody(sessionID: "long", completionID: "native-end")
        #expect(body.text == text)
        let ledger = CompletionResultLedger(url: directory.appendingPathComponent(CompletionResultLedger.fileName))
        #expect(ledger.results.values.first?.text == text)
    }
}
