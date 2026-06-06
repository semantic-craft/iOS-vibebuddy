import Testing
@testable import VibeBuddyKit

@Suite("ToolActivity — tool name to human phrase")
struct ToolActivityTests {
    @Test("known tools map to a short activity")
    func knownTools() {
        #expect(ToolActivity.phrase(for: "Edit") == "Editing")
        #expect(ToolActivity.phrase(for: "MultiEdit") == "Editing")
        #expect(ToolActivity.phrase(for: "Read") == "Reading")
        #expect(ToolActivity.phrase(for: "Bash") == "Running")
        #expect(ToolActivity.phrase(for: "Grep") == "Searching")
        #expect(ToolActivity.phrase(for: "WebSearch") == "Browsing")
        #expect(ToolActivity.phrase(for: "Task") == "Delegating")
        #expect(ToolActivity.phrase(for: "TodoWrite") == "Planning")
    }

    @Test("matching is case-insensitive and trims whitespace")
    func caseInsensitive() {
        #expect(ToolActivity.phrase(for: "bash") == "Running")
        #expect(ToolActivity.phrase(for: "EDIT") == "Editing")
        #expect(ToolActivity.phrase(for: "  grep  ") == "Searching")
    }

    @Test("unknown or missing tool returns nil (caller falls back to summary)")
    func unknownNil() {
        #expect(ToolActivity.phrase(for: "Frobnicate") == nil)
        #expect(ToolActivity.phrase(for: nil) == nil)
        #expect(ToolActivity.phrase(for: "") == nil)
        #expect(ToolActivity.phrase(for: "   ") == nil)
    }
}
