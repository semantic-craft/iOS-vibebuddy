import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("HookParser — raw Claude Code JSON to HookEvent")
struct HookParserTests {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func parse(_ json: String) -> HookEvent? {
        HookParser.parse(Data(json.utf8), receivedAt: now)
    }

    @Test("parses a PreToolUse payload")
    func preToolUse() {
        let e = parse("""
        {"hook_event_name":"PreToolUse","session_id":"abc",
         "cwd":"/Users/me/projects/vibebuddy","tool_name":"Bash",
         "tool_input":{"command":"ls"}}
        """)
        #expect(e?.kind == .preToolUse)
        #expect(e?.sessionID == "abc")
        #expect(e?.cwd == "/Users/me/projects/vibebuddy")
        #expect(e?.toolName == "Bash")
        #expect(e?.timestamp == now)
    }

    @Test("parses a Notification payload with message")
    func notification() {
        let e = parse("""
        {"hook_event_name":"Notification","session_id":"abc",
         "message":"Claude needs your permission to use Bash"}
        """)
        #expect(e?.kind == .notification)
        #expect(e?.message == "Claude needs your permission to use Bash")
    }

    @Test("PostToolUse with an is_error tool_response is flagged as a tool error")
    func postToolUseError() {
        let e = parse("""
        {"hook_event_name":"PostToolUse","session_id":"abc","tool_name":"Bash",
         "tool_response":{"is_error":true,"stdout":"","stderr":"command not found"}}
        """)
        #expect(e?.kind == .postToolUse)
        #expect(e?.toolError == true)
    }

    @Test("PostToolUse with a string tool_response decodes and is not an error")
    func postToolUseStringResponse() {
        let e = parse("""
        {"hook_event_name":"PostToolUse","session_id":"abc","tool_name":"Read",
         "tool_response":"file contents here"}
        """)
        #expect(e?.kind == .postToolUse)          // a string tool_response must not break decoding
        #expect(e?.toolError == false)
    }

    @Test("a successful PostToolUse is not a tool error")
    func postToolUseSuccess() {
        let e = parse("""
        {"hook_event_name":"PostToolUse","session_id":"abc","tool_name":"Bash",
         "tool_response":{"is_error":false,"stdout":"ok"}}
        """)
        #expect(e?.toolError == false)
    }

    @Test("parses a Stop payload")
    func stop() {
        let e = parse("""
        {"hook_event_name":"Stop","session_id":"abc","stop_hook_active":true}
        """)
        #expect(e?.kind == .stop)
        #expect(e?.sessionID == "abc")
    }

    @Test("parses a SessionEnd payload")
    func sessionEnd() {
        let e = parse("""
        {"hook_event_name":"SessionEnd","session_id":"abc","cwd":"/x/proj","reason":"exit"}
        """)
        #expect(e?.kind == .sessionEnd)
        #expect(e?.sessionID == "abc")
        #expect(e?.cwd == "/x/proj")
    }

    @Test("unknown hook_event_name → nil (ignored)")
    func unknownKind() {
        #expect(parse("""
        {"hook_event_name":"PreCompact","session_id":"abc"}
        """) == nil)
    }

    @Test("malformed JSON → nil")
    func malformed() {
        #expect(parse("{not json") == nil)
    }

    @Test("missing session_id → nil")
    func missingSession() {
        #expect(parse("""
        {"hook_event_name":"Stop"}
        """) == nil)
    }

    @Test("parsed events drive the reducer end-to-end")
    func parseThenReduce() {
        var r = SessionReducer()
        let events = [
            parse(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/proj"}"#),
            parse(#"{"hook_event_name":"Notification","session_id":"s","message":"needs your permission"}"#),
        ].compactMap { $0 }
        #expect(events.count == 2)
        for e in events { r.apply(e) }
        #expect(r.sessions["s"]?.status == .needsResponse)
        #expect(r.sessions["s"]?.waitKind == .permission)
        #expect(r.sessions["s"]?.project == "proj")
    }
}
