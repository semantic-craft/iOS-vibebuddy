import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("PermissionRules — load allow/deny from settings.json")
struct PermissionRulesTests {
    @Test("loads allow and deny arrays from a settings file")
    func loadsArrays() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "vb-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"permissions":{"allow":["Bash(ls:*)","Read"],"deny":["Bash(rm:*)"]}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let rules = PermissionRules.load(settingsURL: url)
        #expect(rules.allow == ["Bash(ls:*)", "Read"])
        #expect(rules.deny == ["Bash(rm:*)"])
    }

    @Test("missing file yields empty rules (everything asks)")
    func missingFile() {
        let rules = PermissionRules.load(settingsURL: URL(fileURLWithPath: "/no/such/file.json"))
        #expect(rules.allow.isEmpty)
        #expect(rules.deny.isEmpty)
    }
}

@Suite("GrokPermissionConfig — [permission] allow/deny from ~/.grok/config.toml")
struct GrokPermissionConfigTests {

    @Test("reads multi-line allow/deny arrays and ignores every other section")
    func multiLineArrays() {
        let rules = GrokPermissionConfig.parse("""
        [cli]
        installer = "internal"

        [ui]
        permission_mode = "always-approve"
        deny = ["not-a-permission-rule"]

        [permission]
        deny = [
          "Read(/Users/you/private/**)",   # a comment
          "Bash(rm -rf *)",
        ]
        allow = [
          "Bash(git *)",
          "Bash(gh *)",
        ]

        [models]
        default = "grok-4.6"
        """)
        #expect(rules.allow == ["Bash(git *)", "Bash(gh *)"])
        #expect(rules.deny == ["Read(/Users/you/private/**)", "Bash(rm -rf *)"])
    }

    @Test("reads the single-line array form")
    func singleLine() {
        let rules = GrokPermissionConfig.parse(#"""
        [permission]
        allow = ["Bash(ls:*)", "Read"]
        deny = []
        """#)
        #expect(rules.allow == ["Bash(ls:*)", "Read"])
        #expect(rules.deny.isEmpty)
    }

    @Test("a # inside a rule is not a comment, and escaped quotes survive")
    func quotingEdgeCases() {
        let rules = GrokPermissionConfig.parse(#"""
        [permission]
        allow = ["Bash(grep '#todo' *)", "Bash(echo \"hi\")", 'Bash(awk {print})']
        """#)
        #expect(rules.allow == ["Bash(grep '#todo' *)", #"Bash(echo "hi")"#, "Bash(awk {print})"])
    }

    @Test("a [permission.…] sub-table is not the [permission] table")
    func subTablesIgnored() {
        let rules = GrokPermissionConfig.parse("""
        [permission.hub]
        allow = ["Bash(anything *)"]

        [[permission.rules]]
        allow = ["Bash(also-not *)"]
        """)
        #expect(rules.allow.isEmpty && rules.deny.isEmpty)
    }

    @Test("a missing or unparsable file yields empty rules (everything asks)")
    func missingFile() {
        let rules = GrokPermissionConfig.load(configURL: URL(fileURLWithPath: "/no/such/config.toml"))
        #expect(rules.allow.isEmpty && rules.deny.isEmpty)
        #expect(GrokPermissionConfig.parse("not toml at all").allow.isEmpty)
    }

    @Test("grok merges its own config with the Claude settings; other agents don't")
    func mergedForGrok() throws {
        // Only the grok half is injectable here, so assert the merge by way of
        // the union always containing what the Claude loader found.
        let claude = PermissionRules.load()
        let grok = PermissionRules.load(for: .grok)
        #expect(grok.allow.count >= claude.allow.count)
        #expect(grok.deny.count >= claude.deny.count)
        #expect(claude.allow.allSatisfy { grok.allow.contains($0) })

        let other = PermissionRules.load(for: .claudeCode)
        #expect(other.allow == claude.allow && other.deny == claude.deny)
    }
}
