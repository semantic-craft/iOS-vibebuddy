import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("CodexParser — Codex notify payload")
struct CodexParserTests {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("agent-turn-complete → done event tagged codex")
    func turnComplete() {
        let e = CodexParser.parse(Data(#"""
        {"type":"agent-turn-complete","thread-id":"t1","turn-id":"u1",
         "cwd":"/Users/me/projects/api","last-assistant-message":"Implemented the endpoint."}
        """#.utf8), receivedAt: now)
        #expect(e?.kind == .stop)
        #expect(e?.agent == .codex)
        #expect(e?.sessionID == "t1")
        #expect(e?.cwd == "/Users/me/projects/api")
        #expect(e?.message == "Implemented the endpoint.")
    }

    @Test("falls back to turn-id when thread-id is absent")
    func turnIdFallback() {
        let e = CodexParser.parse(Data(#"{"type":"agent-turn-complete","turn-id":"u9"}"#.utf8),
                                  receivedAt: now)
        #expect(e?.sessionID == "u9")
    }

    @Test("unknown type → nil")
    func unknownType() {
        #expect(CodexParser.parse(Data(#"{"type":"x","thread-id":"t"}"#.utf8), receivedAt: now) == nil)
    }

    @Test("a Claude Code hook payload → nil (wrong parser)")
    func notCodex() {
        #expect(CodexParser.parse(Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8),
                                  receivedAt: now) == nil)
    }

    @Test("parsed Codex event drives the reducer to a done session")
    func endToEnd() {
        var r = SessionReducer()
        let e = CodexParser.parse(Data(#"""
        {"type":"agent-turn-complete","thread-id":"t1","cwd":"/x/svc","last-assistant-message":"all green"}
        """#.utf8), receivedAt: now)!
        r.apply(e)
        let s = r.sessions["t1"]
        #expect(s?.status == .done)
        #expect(s?.agent == .codex)
        #expect(s?.project == "svc")
        #expect(s?.summary == "all green")
    }

    @Test("store ingests Codex notify (auto-detected) and tags it codex")
    func storeAutoDetect() async {
        let store = SessionStore()
        await store.ingest(
            Data(#"{"type":"agent-turn-complete","thread-id":"t","cwd":"/x/svc","last-assistant-message":"ok"}"#.utf8),
            agent: .codex, receivedAt: now)
        let s = await store.snapshot(now: now).sessions.first
        #expect(s?.agent == .codex)
        #expect(s?.status == .done)
        #expect(s?.summary == "ok")
    }
}
