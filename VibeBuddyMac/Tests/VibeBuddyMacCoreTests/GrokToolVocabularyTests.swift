import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("GrokToolVocabulary — grok tool names/keys → the canonical vocabulary")
struct GrokToolVocabularyTests {

    @Test("shell tools map to Bash, both spellings and both aliases")
    func bash() {
        for name in ["run_terminal_command", "run_terminal_cmd", "bash", "shell"] {
            #expect(GrokToolVocabulary.canonicalTool(name) == "Bash")
        }
    }

    @Test("file tools map to the Read/Edit/Write/Grep/Glob names the rules use")
    func fileTools() {
        #expect(GrokToolVocabulary.canonicalTool("read_file") == "Read")
        #expect(GrokToolVocabulary.canonicalTool("hashline_read") == "Read")
        #expect(GrokToolVocabulary.canonicalTool("search_replace") == "Edit")
        #expect(GrokToolVocabulary.canonicalTool("hashline_edit") == "Edit")
        #expect(GrokToolVocabulary.canonicalTool("apply_patch") == "Edit")
        #expect(GrokToolVocabulary.canonicalTool("write") == "Write")
        #expect(GrokToolVocabulary.canonicalTool("write_file") == "Write")
        #expect(GrokToolVocabulary.canonicalTool("create_file") == "Write")
        #expect(GrokToolVocabulary.canonicalTool("grep") == "Grep")
        #expect(GrokToolVocabulary.canonicalTool("list_dir") == "Glob")
    }

    @Test("web and subagent tools map to their Claude counterparts")
    func webAndSubagents() {
        #expect(GrokToolVocabulary.canonicalTool("web_search") == "WebSearch")
        #expect(GrokToolVocabulary.canonicalTool("web_fetch") == "WebFetch")
        #expect(GrokToolVocabulary.canonicalTool("spawn_subagent") == "Task")
    }

    @Test("MCP tools gain the mcp__ prefix, and keep it if already there")
    func mcp() {
        #expect(GrokToolVocabulary.canonicalTool("firecrawl__scrape") == "mcp__firecrawl__scrape")
        #expect(GrokToolVocabulary.canonicalTool("mcp__firecrawl__scrape") == "mcp__firecrawl__scrape")
    }

    @Test("a provider-qualified id is stripped before mapping")
    func qualified() {
        #expect(GrokToolVocabulary.canonicalTool("GrokBuild:read_file") == "Read")
    }

    @Test("an unknown tool passes through unchanged (the matcher then asks)")
    func unknown() {
        #expect(GrokToolVocabulary.canonicalTool("todo_write") == "todo_write")
        #expect(GrokToolVocabulary.canonicalTool("") == "")
    }

    @Test("target_file / target_directory become file_path; the original stays")
    func inputKeys() {
        let read = GrokToolVocabulary.canonicalInput(["target_file": "/x/a.swift", "limit": 20])
        #expect(read["file_path"] as? String == "/x/a.swift")
        #expect(read["target_file"] as? String == "/x/a.swift")
        #expect(read["limit"] as? Int == 20)

        let list = GrokToolVocabulary.canonicalInput(["target_directory": "/x/src"])
        #expect(list["file_path"] as? String == "/x/src")
    }

    @Test("keys grok already spells the canonical way are left alone")
    func nativeKeys() {
        let edit = GrokToolVocabulary.canonicalInput(
            ["file_path": "/x/a.swift", "old_string": "a", "new_string": "b", "replace_all": false])
        #expect(edit["file_path"] as? String == "/x/a.swift")
        #expect(edit["old_string"] as? String == "a")
        #expect(edit["new_string"] as? String == "b")

        let bash = GrokToolVocabulary.canonicalInput(["command": "ls", "description": "list"])
        #expect(bash["command"] as? String == "ls")
    }

    @Test("an explicit file_path is never overwritten by target_file")
    func filePathWins() {
        let input = GrokToolVocabulary.canonicalInput(["file_path": "/keep", "target_file": "/other"])
        #expect(input["file_path"] as? String == "/keep")
    }

    @Test("normalize does both halves at once")
    func normalize() {
        let n = GrokToolVocabulary.normalize(tool: "read_file", input: ["target_file": "/x/a"])
        #expect(n.tool == "Read")
        #expect(n.input["file_path"] as? String == "/x/a")
    }

    // The point of all of the above: the existing agent-agnostic machinery then
    // matches a grok call against rules and always-allow entries unchanged.

    @Test("a normalized grok call matches an ordinary Bash allow rule")
    func matcherAcceptsNormalizedCall() {
        let n = GrokToolVocabulary.normalize(tool: "run_terminal_command", input: ["command": "git status"])
        #expect(PermissionMatcher.decide(tool: n.tool, input: n.input,
                                         allow: ["Bash(git:*)"], deny: []) == .allow)
    }

    @Test("an always-allow rule written from a grok approval is the canonical one")
    func allowRuleIsCanonical() {
        let n = GrokToolVocabulary.normalize(tool: "search_replace",
                                             input: ["file_path": "/x/a.swift", "old_string": "a", "new_string": "b"])
        #expect(AllowRule.forApproval(tool: n.tool, input: n.input) == "Edit(/x/a.swift)")
    }
}
