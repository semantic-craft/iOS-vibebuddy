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

    @Test("a source's own context window overrides the model table")
    func enrichHonoursReportedContextWindow() {
        var r = SessionReducer()
        r.apply(HookEvent(kind: .sessionStart, sessionID: "s", agent: .grok, timestamp: t0))
        r.enrich(sessionID: "s", with: TranscriptInfo(
            model: "grok-4.6", contextTokens: 184_960, contextWindow: 500_000))
        #expect(r.sessions["s"]?.contextWindow == 500_000)
        #expect(r.sessions["s"]?.contextTokens == 184_960)
    }

    @Test("without a reported window the model table answers, 500k for grok")
    func contextWindowByModel() {
        #expect(SessionReducer.contextWindow(for: "claude-opus-4-8") == 200_000)
        #expect(SessionReducer.contextWindow(for: nil) == 200_000)
        #expect(SessionReducer.contextWindow(for: "grok-4.6") == 500_000)

        var r = SessionReducer()
        r.apply(HookEvent(kind: .sessionStart, sessionID: "s", agent: .grok, timestamp: t0))
        r.enrich(sessionID: "s", with: TranscriptInfo(model: "grok-4.6", contextTokens: 1_000))
        #expect(r.sessions["s"]?.contextWindow == 500_000)
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
