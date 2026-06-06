import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("VibeBuddyAllowStore — vibebuddy's own always-allow rules (ADR 0010)")
struct VibeBuddyAllowStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vbtest-\(UUID().uuidString)")
            .appendingPathComponent("permission-allow.json")
    }

    /// Matches the daemon's own evaluation: pull the rules out of the actor, then
    /// match locally with the nonisolated `AllowRule` (mirrors VibeBuddyServer).
    private func allows(_ store: VibeBuddyAllowStore, _ tool: String, _ input: [String: Any]) async -> Bool {
        await store.all().contains { AllowRule.matchesExactly($0, tool: tool, input: input) }
    }

    // MARK: AllowRule.forApproval — what gets persisted

    @Test("Bash → the exact command (never a :* prefix)")
    func deriveBash() {
        #expect(AllowRule.forApproval(tool: "Bash", input: ["command": "  git status  "]) == "Bash(git status)")
        #expect(AllowRule.forApproval(tool: "Bash", input: ["command": ""]) == nil)
    }

    @Test("file tools → the target path; other tools → the bare tool")
    func deriveFileAndBare() {
        #expect(AllowRule.forApproval(tool: "Edit", input: ["file_path": "/a/b.swift"]) == "Edit(/a/b.swift)")
        #expect(AllowRule.forApproval(tool: "WebFetch", input: [:]) == "WebFetch")
        #expect(AllowRule.forApproval(tool: "Edit", input: [:]) == nil)
    }

    // MARK: matchesExactly — exact, not glob

    @Test("an exact Bash rule matches only that exact command")
    func matchExactBash() {
        #expect(AllowRule.matchesExactly("Bash(git status)", tool: "Bash", input: ["command": "git status"]))
        #expect(!AllowRule.matchesExactly("Bash(git status)", tool: "Bash", input: ["command": "git status -v"]))
    }

    @Test("a bare-tool rule matches any input for that tool")
    func matchBareTool() {
        #expect(AllowRule.matchesExactly("WebFetch", tool: "WebFetch", input: ["url": "x"]))
        #expect(!AllowRule.matchesExactly("WebFetch", tool: "Bash", input: [:]))
    }

    // MARK: persistence round-trip

    @Test("add persists across instances; allows() matches exactly")
    func roundTrip() async {
        let url = tempURL()
        let store = VibeBuddyAllowStore(url: url)
        #expect(await allows(store, "Bash", ["command": "git status"]) == false)
        await store.add("Bash(git status)")

        // A fresh instance reads the same file back.
        let reopened = VibeBuddyAllowStore(url: url)
        #expect(await allows(reopened, "Bash", ["command": "git status"]))
        #expect(await allows(reopened, "Bash", ["command": "rm -rf /"]) == false)
        #expect(await reopened.all() == ["Bash(git status)"])

        // clear() empties and persists.
        await reopened.clear()
        #expect(await VibeBuddyAllowStore(url: url).all().isEmpty)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("add is idempotent — no duplicates")
    func noDuplicates() async {
        let url = tempURL()
        let store = VibeBuddyAllowStore(url: url)
        #expect(await store.add("Edit(/a.swift)") == true)
        #expect(await store.add("Edit(/a.swift)") == false)
        #expect(await store.all() == ["Edit(/a.swift)"])
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
