import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("ApprovalDetails — tool_input → rich approval card fields")
struct ApprovalDetailsTests {

    @Test("Bash carries the full command and previews it")
    func bash() {
        let d = ApprovalDetails.from(tool: "Bash", input: ["command": "npm test -- --watch"])
        #expect(d.command == "npm test -- --watch")
        #expect(d.commandPreview == "npm test -- --watch")
        #expect(d.filePath == nil && d.oldText == nil && d.newText == nil)
    }

    @Test("Edit carries path + old/new for a diff (old_string/new_string)")
    func edit() {
        let d = ApprovalDetails.from(tool: "Edit",
            input: ["file_path": "/x/a.swift", "old_string": "foo", "new_string": "bar"])
        #expect(d.filePath == "/x/a.swift")
        #expect(d.oldText == "foo")
        #expect(d.newText == "bar")
        #expect(d.command == nil)
        #expect(d.commandPreview == "/x/a.swift")
    }

    @Test("Edit also accepts the old_text/new_text key spelling")
    func editAltKeys() {
        let d = ApprovalDetails.from(tool: "Edit",
            input: ["file_path": "/x", "old_text": "a", "new_text": "b"])
        #expect(d.oldText == "a" && d.newText == "b")
    }

    @Test("Write carries path + new content")
    func write() {
        let d = ApprovalDetails.from(tool: "Write",
            input: ["file_path": "/x/b.swift", "content": "hello world"])
        #expect(d.filePath == "/x/b.swift")
        #expect(d.newText == "hello world")
        #expect(d.oldText == nil)
    }

    @Test("Read carries only the path")
    func read() {
        let d = ApprovalDetails.from(tool: "Read", input: ["file_path": "/x/c.swift"])
        #expect(d.filePath == "/x/c.swift")
        #expect(d.command == nil && d.oldText == nil && d.newText == nil)
        #expect(d.commandPreview == "/x/c.swift")
    }

    @Test("large fields are capped at 6 KB")
    func capped() {
        let big = String(repeating: "x", count: 7000)
        let d = ApprovalDetails.from(tool: "Write", input: ["file_path": "/x", "content": big])
        #expect(d.newText?.count == 6 * 1024)
    }

    @Test("WebFetch falls back to the url for its preview")
    func webFetch() {
        let d = ApprovalDetails.from(tool: "WebFetch", input: ["url": "https://example.com/x"])
        #expect(d.commandPreview == "https://example.com/x")
    }
}

@Suite("ApprovalPayload — PreToolUse envelope → tool / input / session / mode")
struct ApprovalPayloadTests {

    @Test("a Claude-shape payload decodes from the snake_case keys, unchanged")
    func claude() {
        let obj: [String: Any] = ["tool_name": "Bash", "session_id": "s",
                                  "tool_input": ["command": "ls"]]
        let call = ApprovalPayload.decode(obj, agent: .claudeCode)
        #expect(call.tool == "Bash")
        #expect(call.sessionID == "s")
        #expect(call.input["command"] as? String == "ls")
        #expect(call.permissionMode == nil)
    }

    @Test("a grok payload decodes camelCase and normalizes the tool vocabulary")
    func grokBash() {
        let obj: [String: Any] = ["toolName": "run_terminal_command", "sessionId": "gs",
                                  "permissionMode": "bypassPermissions", "toolUseId": "call-1",
                                  "toolInput": ["command": "npm test", "description": "run tests"]]
        let call = ApprovalPayload.decode(obj, agent: .grok)
        #expect(call.tool == "Bash")
        #expect(call.sessionID == "gs")
        #expect(call.permissionMode == "bypassPermissions")

        let d = ApprovalDetails.from(tool: call.tool, input: call.input)
        #expect(d.command == "npm test")
        #expect(d.commandPreview == "npm test")
    }

    @Test("grok read_file: target_file becomes the approval card's file path")
    func grokRead() {
        let obj: [String: Any] = ["toolName": "read_file", "sessionId": "gs",
                                  "toolInput": ["target_file": "/x/a.swift", "limit": 40]]
        let call = ApprovalPayload.decode(obj, agent: .grok)
        #expect(call.tool == "Read")
        let d = ApprovalDetails.from(tool: call.tool, input: call.input)
        #expect(d.filePath == "/x/a.swift")
        #expect(d.commandPreview == "/x/a.swift")
    }

    @Test("grok search_replace produces a diff preview from old_string/new_string")
    func grokEdit() {
        let obj: [String: Any] = ["toolName": "search_replace", "sessionId": "gs",
                                  "toolInput": ["file_path": "/x/a.swift",
                                                "old_string": "let a = 1",
                                                "new_string": "let a = 2",
                                                "replace_all": false]]
        let call = ApprovalPayload.decode(obj, agent: .grok)
        #expect(call.tool == "Edit")
        let d = ApprovalDetails.from(tool: call.tool, input: call.input)
        #expect(d.filePath == "/x/a.swift")
        #expect(d.oldText == "let a = 1")
        #expect(d.newText == "let a = 2")
    }

    @Test("an empty or missing permissionMode decodes as nil")
    func modeOptional() {
        #expect(ApprovalPayload.decode(["toolName": "grep", "permissionMode": ""],
                                       agent: .grok).permissionMode == nil)
        #expect(ApprovalPayload.decode(["toolName": "grep"], agent: .grok).permissionMode == nil)
    }

    @Test("a junk payload decodes to empty fields rather than failing")
    func junk() {
        let call = ApprovalPayload.decode([:], agent: .grok)
        #expect(call.tool.isEmpty && call.sessionID.isEmpty && call.input.isEmpty)
    }
}
