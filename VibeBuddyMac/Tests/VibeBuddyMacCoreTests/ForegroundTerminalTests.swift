import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("ForegroundTerminal — which sessions the user is looking at")
struct ForegroundTerminalTests {

    private func session(_ id: String, term: String?) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, status: .done,
                     terminalRef: term.map { TerminalRef(termProgram: $0) },
                     statusSince: .init(timeIntervalSince1970: 0),
                     updatedAt: .init(timeIntervalSince1970: 0))
    }

    @Test("a session whose terminal app is frontmost is focused")
    func matchFrontmost() {
        let sessions = [session("a", term: "ghostty"), session("b", term: "iTerm.app")]
        #expect(ForegroundTerminal.focusedSessionIDs(among: sessions,
                frontmostBundleID: "com.mitchellh.ghostty") == ["a"])
    }

    @Test("a different (non-terminal) app frontmost → nobody is focused")
    func noMatch() {
        let sessions = [session("a", term: "ghostty")]
        #expect(ForegroundTerminal.focusedSessionIDs(among: sessions,
                frontmostBundleID: "com.apple.finder").isEmpty)
    }

    @Test("Warp is recognized under its stable bundle id")
    func warp() {
        let sessions = [session("a", term: "WarpTerminal")]
        #expect(ForegroundTerminal.focusedSessionIDs(among: sessions,
                frontmostBundleID: "dev.warp.Warp-Stable") == ["a"])
    }

    @Test("two sessions sharing the frontmost terminal app are both focused (tab-level is unknowable)")
    func sharedApp() {
        let sessions = [session("a", term: "ghostty"), session("b", term: "ghostty"),
                        session("c", term: "iTerm.app")]
        #expect(ForegroundTerminal.focusedSessionIDs(among: sessions,
                frontmostBundleID: "com.mitchellh.ghostty") == ["a", "b"])
    }

    @Test("a session in an embedded terminal is matched by its captured host bundle id")
    func hostBundleID() {
        let embedded = AgentSession(id: "a", agent: .claudeCode, project: "a", status: .done,
                                    terminalRef: TerminalRef(hostBundleId: "com.anthropic.claude-code"),
                                    statusSince: .init(timeIntervalSince1970: 0),
                                    updatedAt: .init(timeIntervalSince1970: 0))
        #expect(ForegroundTerminal.focusedSessionIDs(among: [embedded],
                frontmostBundleID: "com.anthropic.claude-code") == ["a"])
        #expect(ForegroundTerminal.focusedSessionIDs(among: [embedded],
                frontmostBundleID: "com.mitchellh.ghostty").isEmpty)
    }

    @Test("no frontmost / no terminalRef → empty")
    func nilCases() {
        #expect(ForegroundTerminal.focusedSessionIDs(among: [session("a", term: nil)],
                frontmostBundleID: "com.mitchellh.ghostty").isEmpty)
        #expect(ForegroundTerminal.focusedSessionIDs(among: [session("a", term: "ghostty")],
                frontmostBundleID: nil).isEmpty)
    }
}
