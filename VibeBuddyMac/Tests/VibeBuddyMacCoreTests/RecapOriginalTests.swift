import Foundation
import Testing
@testable import VibeBuddyMacCore

struct RecapOriginalTests {
    @Test func claudeOriginalIsRetainedWithoutCompletionNotifications() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date().addingTimeInterval(-0.3)
        let ended = Date().addingTimeInterval(-0.1)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let original = "The duplicate alert was fixed. Device acceptance is still pending."
        let row: [String: Any] = ["sessionId": "s", "type": "assistant",
            "timestamp": formatter.string(from: start.addingTimeInterval(0.1)),
            "message": ["role": "assistant", "stop_reason": "end_turn",
                        "content": [["type": "text", "text": original]]]]
        var bytes = try JSONSerialization.data(withJSONObject: row)
        bytes.append(10)
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        try bytes.write(to: transcript)
        let journal = directory.appendingPathComponent("lifecycle.json")
        let ledger = directory.appendingPathComponent("recap-ledger.json")
        let store = SessionStore(sourceID: "mac", journalURL: journal)
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", timestamp: start))
        _ = await store.snapshot(now: start)
        let stop = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s",
            "transcript_path": transcript.path, "last_assistant_message": original])
        await store.ingest(stop, receivedAt: ended)
        let snapshot = await store.snapshot(now: ended)
        let entry = try #require(snapshot.recap?.entries.first)
        #expect(snapshot.sessions.first?.completionNotice == nil)
        var retained: String?
        for _ in 0..<100 {
            retained = RecapLedger(url: ledger).entries[entry.id]?.resultText
            if retained != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(retained == original)
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", timestamp: Date()))
        _ = await store.snapshot(now: Date())
        #expect(RecapLedger(url: ledger).entries[entry.id]?.resultText == original)
    }
}
