import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("SessionStore — termination & self-healing")
struct SessionStoreTests {

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a SessionEnd hook removes the session end-to-end")
    func sessionEndRemoves() async throws {
        let store = SessionStore()
        await store.ingest(
            Data(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/proj"}"#.utf8),
            receivedAt: t0)
        #expect(await store.snapshot(now: t0).sessions.count == 1)

        await store.ingest(
            Data(#"{"hook_event_name":"SessionEnd","session_id":"s","cwd":"/x/proj"}"#.utf8),
            receivedAt: t0.addingTimeInterval(1))
        #expect(await store.snapshot(now: t0.addingTimeInterval(1)).sessions.isEmpty)
    }

    @Test("sweep drops a needsResponse idle past staleAfter")
    func sweepDropsStale() async throws {
        let store = SessionStore(staleAfter: 60)
        await store.ingest(
            Data(#"{"hook_event_name":"Notification","session_id":"s","cwd":"/x/proj","message":"waiting for your input"}"#.utf8),
            receivedAt: t0)
        #expect(await store.snapshot(now: t0).sessions.first?.status == .needsResponse)

        await store.sweep(now: t0.addingTimeInterval(120))   // 120s > 60s staleAfter
        #expect(await store.snapshot(now: t0.addingTimeInterval(120)).sessions.isEmpty)
    }

    @Test("sweep drops a needsResponse whose transcript advanced after it began waiting")
    func sweepReconcilesFromTranscript() async throws {
        let tmp = NSTemporaryDirectory() + "vb-sweep-\(UUID().uuidString).jsonl"
        try "{}".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = SessionStore(staleAfter: 86_400)   // long, so only the transcript rule can fire
        let payload = #"{"hook_event_name":"Notification","session_id":"s","cwd":"/x/proj","message":"waiting for your input","transcript_path":"\#(tmp)"}"#
        await store.ingest(Data(payload.utf8), receivedAt: t0)   // statusSince = t0
        #expect(await store.snapshot(now: t0).sessions.first?.status == .needsResponse)

        // The transcript was modified AFTER the wait began → the prompt was answered.
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(100)], ofItemAtPath: tmp)
        await store.sweep(now: t0.addingTimeInterval(200))
        #expect(await store.snapshot(now: t0.addingTimeInterval(200)).sessions.isEmpty)
    }
}
