import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("CodexToolVocabulary — Codex PermissionRequest tool names/keys → the canonical vocabulary")
struct CodexToolVocabularyTests {

    @Test("Bash and MCP names already are canonical and pass through")
    func passthrough() {
        #expect(CodexToolVocabulary.canonicalTool("Bash") == "Bash")
        #expect(CodexToolVocabulary.canonicalTool("mcp__fs__read") == "mcp__fs__read")
        #expect(CodexToolVocabulary.canonicalTool("something_new") == "something_new")
    }

    @Test("apply_patch is the Edit alias Codex's own matcher uses")
    func applyPatch() {
        #expect(CodexToolVocabulary.canonicalTool("apply_patch") == "Edit")
    }

    @Test("a single-file patch gains a file_path so Edit(<path>) rules can match it")
    func singleFilePatchGetsPath() {
        let patch = "*** Begin Patch\n*** Update File: src/app.swift\n@@\n-a\n+b\n*** End Patch"
        let input = CodexToolVocabulary.canonicalInput(tool: "apply_patch", ["command": patch])
        #expect(input["file_path"] as? String == "src/app.swift")
        #expect(input["command"] as? String == patch)   // original key kept
    }

    @Test("a multi-file patch stays path-less, so the matcher keeps asking")
    func multiFilePatchStaysPathless() {
        let patch = "*** Begin Patch\n*** Add File: a.txt\n+x\n*** Delete File: b.txt\n*** End Patch"
        let input = CodexToolVocabulary.canonicalInput(tool: "apply_patch", ["command": patch])
        #expect(input["file_path"] == nil)
        #expect(CodexToolVocabulary.patchedFiles(patch) == ["a.txt", "b.txt"])
    }

    @Test("a rename touches its destination too, so it stays path-less")
    func moveTouchesDestination() {
        let patch = "*** Begin Patch\n*** Update File: old.txt\n*** Move to: new.txt\n@@\n-a\n+b\n*** End Patch"
        #expect(CodexToolVocabulary.patchedFiles(patch) == ["old.txt", "new.txt"])
        #expect(CodexToolVocabulary.canonicalInput(tool: "apply_patch", ["command": patch])["file_path"] == nil)
    }

    @Test("other tools' inputs are untouched")
    func otherTools() {
        let bash = CodexToolVocabulary.canonicalInput(tool: "Bash", ["command": "ls"])
        #expect(bash["file_path"] == nil)
        #expect(bash["command"] as? String == "ls")
    }
}
