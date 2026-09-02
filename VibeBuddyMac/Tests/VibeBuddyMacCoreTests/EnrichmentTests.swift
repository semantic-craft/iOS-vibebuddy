import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("Transcript enrichment wiring")
struct EnrichmentTests {

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("parser reads transcript_path")
    func parsesTranscriptPath() {
        let e = HookParser.parse(
            Data(#"{"hook_event_name":"Stop","session_id":"s","transcript_path":"/tmp/x.jsonl"}"#.utf8),
            receivedAt: t0
        )
        #expect(e?.transcriptPath == "/tmp/x.jsonl")
    }

    @Test("reducer.enrich sets model, tokens, and a summary when not waiting")
    func enrichSetsFields() {
        var r = SessionReducer()
        r.apply(HookEvent(kind: .sessionStart, sessionID: "s", cwd: "/x/p", timestamp: t0))
        r.enrich(sessionID: "s",
                 with: TranscriptInfo(model: "claude-opus-4-8", tokens: 4242, summary: "did a thing"))
        #expect(r.sessions["s"]?.model == "claude-opus-4-8")
        #expect(r.sessions["s"]?.tokens == 4242)
        #expect(r.sessions["s"]?.summary == "did a thing")
    }

    @Test("enrich does not overwrite a needsResponse prompt summary")
    func enrichKeepsPromptSummary() {
        var r = SessionReducer()
        r.apply(HookEvent(kind: .sessionStart, sessionID: "s", timestamp: t0))
        r.apply(HookEvent(kind: .notification, sessionID: "s",
                          message: "needs your permission", timestamp: t0.addingTimeInterval(1)))
        r.enrich(sessionID: "s", with: TranscriptInfo(model: "m", tokens: 10, summary: "some prose"))
        #expect(r.sessions["s"]?.summary == "needs your permission")  // prompt kept
        #expect(r.sessions["s"]?.model == "m")                        // still enriched
        #expect(r.sessions["s"]?.tokens == 10)
    }

    @Test("enrich on an unknown session is ignored")
    func enrichUnknown() {
        var r = SessionReducer()
        r.enrich(sessionID: "ghost", with: TranscriptInfo(model: "m"))
        #expect(r.sessions["ghost"] == nil)
    }

    @Test("store ingest enriches the session from its transcript file")
    func storeEnriches() async throws {
        let tmp = NSTemporaryDirectory() + "vb-enrich-\(UUID().uuidString).jsonl"
        let line = #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"text","text":"finished refactor"}],"usage":{"input_tokens":900,"output_tokens":100}}}"#
        try line.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = SessionStore()
        let payload = #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/proj","transcript_path":"\#(tmp)"}"#
        await store.ingest(Data(payload.utf8), receivedAt: t0)

        let s = await store.snapshot(now: t0).sessions.first
        #expect(s?.status == .done)
        #expect(s?.model == "claude-opus-4-8")
        #expect(s?.tokens == 1000)
        #expect(s?.summary == "finished refactor")
    }
}
