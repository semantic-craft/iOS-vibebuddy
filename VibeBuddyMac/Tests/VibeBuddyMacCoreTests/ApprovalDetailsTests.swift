import Testing
import Foundation
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
}
