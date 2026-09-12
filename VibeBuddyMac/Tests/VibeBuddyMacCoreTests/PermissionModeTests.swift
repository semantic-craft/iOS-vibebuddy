import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Reported permission metadata")
struct PermissionModeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Claude latest explicit mode wins without changing real waiting; Cursor stays unknown")
    func modesAndWaiting() throws {
        var reducer = SessionReducer()
        func hook(_ type: String, mode: String, at: Date) throws -> HookEvent {
            let data = Data("{\"hook_event_name\":\"\(type)\",\"session_id\":\"s\",\"permission_mode\":\"\(mode)\",\"notification_type\":\"permission_prompt\"}".utf8)
            return try #require(HookParser.parse(data, receivedAt: at))
        }
        reducer.apply(try hook("UserPromptSubmit", mode: "auto", at: now))
        #expect(reducer.snapshot(now: now).sessions.first?.permissionMode == .auto)
        reducer.apply(try hook("Notification", mode: "bypassPermissions", at: now.addingTimeInterval(1)))
        var session = try #require(reducer.snapshot(now: now.addingTimeInterval(1)).sessions.first)
        #expect(session.permissionMode == .bypass)
        #expect(StateGroups([session]).needsYou.count == 1)
        reducer.apply(try hook("PreToolUse", mode: "auto", at: now.addingTimeInterval(-1)))
        #expect(reducer.snapshot(now: now).sessions.first?.permissionMode == .bypass)
        #expect(PermissionMode.reported("auto", by: .cursor) == .unknown)
        #expect(PermissionMode.reported("never", by: .codex) == .unknown)
        #expect(PermissionMode.reported("future", by: .claudeCode) == .unknown)
        session.permissionMode = nil
        let encoded = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(AgentSession.self, from: encoded).permissionMode == nil)
    }

    @Test("Codex reports independent approval and sandbox raw values even when model stays the same")
    func codexPolicies() throws {
        var parser = CodexRolloutParser()
        var reducer = SessionReducer()
        let records = [
            #"{"type":"session_meta","payload":{"id":"codex-mode","originator":"Codex Desktop","cwd":"/tmp/mode"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-test","approval_policy":"never","sandbox_policy":{"type":"read-only"}}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-test","approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"}}}"#
        ]
        for (index, record) in records.enumerated() {
            for event in parser.parseEvents(Data(record.utf8), receivedAt: now.addingTimeInterval(Double(index))) {
                reducer.apply(event)
            }
        }
        let session = try #require(reducer.snapshot(now: now.addingTimeInterval(4)).sessions.first)
        #expect(session.approvalPolicyRaw == "on-request")
        #expect(session.sandboxPolicyRaw == #"{"type":"workspace-write"}"#)
        #expect(session.permissionMode == .unknown)
        #expect(session.status == .working)
    }
}
