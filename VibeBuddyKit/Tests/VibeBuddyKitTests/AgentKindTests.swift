import Testing
@testable import VibeBuddyKit

@Suite("AgentKind — source mapping & display")
struct AgentKindTests {

    @Test("known sources and aliases map to the right kind")
    func sources() {
        #expect(AgentKind.fromSource("codex") == .codex)
        #expect(AgentKind.fromSource("qwen-code") == .qwen)
        #expect(AgentKind.fromSource("kimi") == .kimi)
        #expect(AgentKind.fromSource("antigravity") == .antigravity)
        #expect(AgentKind.fromSource("gemini") == .antigravity)
        #expect(AgentKind.fromSource("grok") == .grok)
        #expect(AgentKind.fromSource("opencode") == .opencode)
        #expect(AgentKind.fromSource("github-copilot") == .copilot)
        #expect(AgentKind.fromSource("claude") == .claudeCode)
    }

    @Test("an unknown or missing source defaults to Claude Code")
    func defaults() {
        #expect(AgentKind.fromSource(nil) == .claudeCode)
        #expect(AgentKind.fromSource("totally-unknown") == .claudeCode)
    }

    @Test("every kind has a non-empty display name and glyph")
    func metadata() {
        for kind in AgentKind.allCases {
            #expect(!kind.displayName.isEmpty)
            #expect(!kind.shortName.isEmpty)
            #expect(!kind.symbolName.isEmpty)
        }
    }

    @Test("legacy wire raw values stay stable")
    func wireStable() {
        #expect(AgentKind.claudeCode.rawValue == "claudeCode")
        #expect(AgentKind.codex.rawValue == "codex")
    }
}
