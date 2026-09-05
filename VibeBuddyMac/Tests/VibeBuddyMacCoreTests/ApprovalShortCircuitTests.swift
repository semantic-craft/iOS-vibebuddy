import Testing
@testable import VibeBuddyMacCore

@Suite("ApprovalShortCircuit — silent-allow boundary")
struct ApprovalShortCircuitTests {
    private func allows(_ tool: String, _ mode: String?) -> Bool {
        ApprovalShortCircuit.autoAllows(tool: tool, permissionMode: mode)
    }

    @Test("bypassPermissions allows everything, MCP tools included")
    func bypassAllowsAll() {
        #expect(allows("Bash", "bypassPermissions"))
        #expect(allows("Edit", "bypassPermissions"))
        #expect(allows("mcp__github__create_issue", "bypassPermissions"))
    }

    @Test("read-only tools are allowed in every mode, including no mode at all")
    func readOnlyEverywhere() {
        for mode in ["default", "plan", "acceptEdits", "auto", "dontAsk", nil] {
            #expect(allows("Read", mode), "Read in \(mode ?? "nil")")
            #expect(allows("Grep", mode), "Grep in \(mode ?? "nil")")
            #expect(allows("WebFetch", mode), "WebFetch in \(mode ?? "nil")")
        }
    }

    @Test("acceptEdits also allows the edit tools, but not Bash")
    func acceptEditsAllowsEdits() {
        #expect(allows("Edit", "acceptEdits"))
        #expect(allows("Write", "acceptEdits"))
        #expect(allows("NotebookEdit", "acceptEdits"))
        #expect(!allows("Bash", "acceptEdits"))
    }

    @Test("default, plan, auto, dontAsk and nil still hold Bash and edits")
    func conservativeModesHold() {
        for mode in ["default", "plan", "auto", "dontAsk", nil] {
            #expect(!allows("Bash", mode), "Bash in \(mode ?? "nil")")
            #expect(!allows("Edit", mode), "Edit in \(mode ?? "nil")")
        }
    }

    @Test("MCP tools are never read-only")
    func mcpNeverReadOnly() {
        #expect(!allows("mcp__filesystem__read_file", "default"))
        #expect(!allows("mcp__filesystem__read_file", "acceptEdits"))
    }
}
