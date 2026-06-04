import Testing
import Foundation
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
