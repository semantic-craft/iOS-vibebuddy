import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("SessionStore — recent output")
struct RecentOutputStoreTests {

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Claude transcript path becomes a sourced, bounded slice")
    func claudeSource() async throws {
        let path = NSTemporaryDirectory() + "vb-ro-\(UUID().uuidString).jsonl"
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix it"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"plan"},{"type":"text","text":"done"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = SessionStore()
        let payload = #"{"hook_event_name":"Stop","session_id":"s","cwd":"/x/demo","transcript_path":"\#(path)"}"#
        await store.ingest(Data(payload.utf8), receivedAt: t0)

        let before = try #require(await store.snapshot(now: t0).sessions.first)
        #expect(before.hasUnreadCompletion)

        let output = await store.recentOutput(sessionID: "s")
        #expect(output.source == .transcript)
        #expect(output.unavailable == nil)
        #expect(output.entries.map(\.text) == ["fix it", "done"])
        #expect(output.updatedAt != nil)

        let after = try #require(await store.snapshot(now: t0).sessions.first)
        #expect(after.hasUnreadCompletion == true)
        #expect(after.statusSince == before.statusSince)
    }

    @Test("Codex rollout path is parsed as rollout, not as a Claude transcript")
    func codexRolloutSource() async throws {
        let path = NSTemporaryDirectory() + "rollout-\(UUID().uuidString).jsonl"
        let lines = [
            #"{"timestamp":"2026-09-02T01:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ship it"}]}}"#,
            #"{"timestamp":"2026-09-02T01:00:01Z","type":"response_item","payload":{"type":"reasoning","summary":[{"text":"nope"}]}}"#,
            #"{"timestamp":"2026-09-02T01:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"shipped"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = SessionStore()
        await store.ingest(
            HookEvent(kind: .sessionStart, sessionID: "thread-1", agent: .codex,
                      transcriptPath: path, observationSource: .rollout, timestamp: t0),
            recordsEvidence: true)

        let output = await store.recentOutput(sessionID: "thread-1")
        #expect(output.source == .rollout)
        #expect(output.entries.map(\.text) == ["ship it", "shipped"])
    }

    @Test("an unknown session is unavailable and invents no dialogue")
    func unknownSession() async {
        let output = await SessionStore().recentOutput(sessionID: "missing")
        #expect(output.unavailable == .unknownSession)
        #expect(output.entries.isEmpty)
    }

    @Test("a known session with no source says so")
    func noSource() async {
        let store = SessionStore()
        await store.ingest(
            Data(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#.utf8),
            receivedAt: t0)
        let output = await store.recentOutput(sessionID: "s")
        #expect(output.unavailable == .noSource)
        #expect(output.entries.isEmpty)
    }
}
