import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("Transcript enrichment wiring")
struct EnrichmentTests {

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

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

    @Test("a source's own context window overrides the model table")
    func enrichHonoursReportedContextWindow() {
        var r = SessionReducer()
        r.apply(HookEvent(kind: .sessionStart, sessionID: "s", agent: .grok, timestamp: t0))
        r.enrich(sessionID: "s", with: TranscriptInfo(
            model: "grok-4.6", contextTokens: 184_960, contextWindow: 500_000))
        #expect(r.sessions["s"]?.contextWindow == 500_000)
        #expect(r.sessions["s"]?.contextTokens == 184_960)
    }

    @Test("enrich carries a branch, and a running tool only into a working gap")
    func enrichBranchAndTool() {
        var r = SessionReducer()
        r.apply(HookEvent(kind: .sessionStart, sessionID: "s", agent: .grok, timestamp: t0))
        r.apply(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .grok,
                          timestamp: t0.addingTimeInterval(1)))
        r.enrich(sessionID: "s", with: TranscriptInfo(
            branch: "feature/fixture", activeTool: "run_terminal_command"))
        #expect(r.sessions["s"]?.branch == "feature/fixture")
        #expect(r.sessions["s"]?.activeTool == "run_terminal_command")

        // nil is "no opinion": clearing stays with the PostToolUse hook, so a
        // read that races the log write cannot blank a live tool.
        r.enrich(sessionID: "s", with: TranscriptInfo(summary: "still going"))
        #expect(r.sessions["s"]?.activeTool == "run_terminal_command")

        // Nor may it rename the tool the hooks are reporting.
        r.enrich(sessionID: "s", with: TranscriptInfo(activeTool: "read_file"))
        #expect(r.sessions["s"]?.activeTool == "run_terminal_command")
    }

    @Test("a settled or waiting session never takes a running tool from the source")
    func enrichNeverToolsASettledSession() {
        // The log lags the hooks: `stop` fires before `turn_completed` is
        // written, so a finished turn's tail still shows an open tool call.
        for kind in [HookEvent.Kind.stop, .notification] {
            var r = SessionReducer()
            r.apply(HookEvent(kind: .sessionStart, sessionID: "s", agent: .grok, timestamp: t0))
            r.apply(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .grok,
                              timestamp: t0.addingTimeInterval(1)))
            r.apply(HookEvent(kind: kind, sessionID: "s", agent: .grok,
                              message: "Permission required",
                              timestamp: t0.addingTimeInterval(2)))
            r.enrich(sessionID: "s", with: TranscriptInfo(activeTool: "run_terminal_command"))
            #expect(r.sessions["s"]?.activeTool == nil)
        }
    }

    @Test("a waiting session names the tool its own permission prompt is blocked on")
    func enrichNamesPendingPermission() {
        var r = SessionReducer()
        r.apply(HookEvent(kind: .sessionStart, sessionID: "s", agent: .grok, timestamp: t0))
        r.apply(HookEvent(kind: .notification, sessionID: "s", agent: .grok,
                          message: "Permission required", timestamp: t0.addingTimeInterval(1)))
        r.enrich(sessionID: "s", with: TranscriptInfo(
            summary: "prose that must not clobber the prompt",
            pendingPermissionTool: "run_terminal_command"))
        #expect(r.sessions["s"]?.waitKind == .permission)
        #expect(r.sessions["s"]?.summary == "Permission required: run_terminal_command")
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

    @Test("a transcript read between status-line samples keeps the 1M window and display name (AI-10)")
    func statusLineWindowSurvivesTranscript() async throws {
        let tmp = NSTemporaryDirectory() + "vb-enrich-\(UUID().uuidString).jsonl"
        let line = #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"working"}],"usage":{"input_tokens":40000,"cache_read_input_tokens":39,"output_tokens":10}}}"#
        try line.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = SessionStore()
        let prompt = #"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/x/proj"}"#
        await store.ingest(Data(prompt.utf8), receivedAt: t0)
        let doc = #"{"session_id":"s","cwd":"/x/proj","model":{"id":"claude-opus-5-5[1m]","display_name":"Opus 5.5 (1M context)"},"context_window":{"context_window_size":1000000,"used_percentage":3.0}}"#
        let json = try #require(try JSONSerialization.jsonObject(with: Data(doc.utf8)) as? [String: Any])
        let sample = try #require(StatusLineSample.decode(json))
        #expect(await store.applyStatusLine(sample, at: t0.addingTimeInterval(1)))

        let tool = #"{"hook_event_name":"PostToolUse","session_id":"s","cwd":"/x/proj","tool_name":"Bash","transcript_path":"\#(tmp)"}"#
        await store.ingest(Data(tool.utf8), receivedAt: t0.addingTimeInterval(2))

        let s = try #require(await store.snapshot(now: t0).sessions.first)
        #expect(s.contextTokens == 40_039)          // the transcript still moves the count
        #expect(s.contextWindow == 1_000_000)       // not the model table's 200k
        #expect(s.model == "Opus 5.5 (1M context)") // not the transcript's raw id
    }

    @Test("the status line's hold on window and model ends with a model switch or the session (AI-10)")
    func statusLineHoldEnds() throws {
        let doc = #"{"session_id":"s","model":{"id":"claude-opus-5-5[1m]","display_name":"Opus 5.5 (1M context)"},"context_window":{"context_window_size":1000000,"used_percentage":3.0}}"#
        let json = try #require(try JSONSerialization.jsonObject(with: Data(doc.utf8)) as? [String: Any])
        let sample = try #require(StatusLineSample.decode(json))
        let transcript = TranscriptInfo(model: "claude-sonnet-5", contextTokens: 1_000)

        var r = SessionReducer()
        r.apply(HookEvent(kind: .sessionStart, sessionID: "s", timestamp: t0))
        _ = r.applyStatusLine(sample)
        r.apply(HookEvent(kind: .sessionMetadataChanged, sessionID: "s", model: "claude-sonnet-5",
                          timestamp: t0.addingTimeInterval(1)))
        r.enrich(sessionID: "s", with: transcript)
        #expect(r.sessions["s"]?.contextWindow == 200_000)

        _ = r.applyStatusLine(sample)
        r.apply(HookEvent(kind: .sessionEnd, sessionID: "s", timestamp: t0.addingTimeInterval(2)))
        r.apply(HookEvent(kind: .sessionStart, sessionID: "s", timestamp: t0.addingTimeInterval(3)))
        r.enrich(sessionID: "s", with: transcript)
        #expect(r.sessions["s"]?.model == "claude-sonnet-5")
        #expect(r.sessions["s"]?.contextWindow == 200_000)
    }
}
