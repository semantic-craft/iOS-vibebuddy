import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("TerminalInjector.commands")
struct TerminalInjectorTests {
    @Test("tmux ref injects literal text then Enter")
    func tmuxLiteralAnswer() {
        let ref = TerminalRef(termProgram: "ghostty", tmux: "/tmp/tmux-501/default,1234,0", tmuxPane: "%3")
        let commands = TerminalInjector.commands(for: ref, text: "Use the main branch")
        let tmux = TerminalCommand.tmuxPath()
        #expect(commands == [
            [tmux, "-S", "/tmp/tmux-501/default", "send-keys", "-t", "%3", "-l", "Use the main branch"],
            [tmux, "-S", "/tmp/tmux-501/default", "send-keys", "-t", "%3", "Enter"],
        ])
    }

    @Test("non-tmux refs are not injected")
    func noTmux() {
        let ref = TerminalRef(termProgram: "iTerm.app")
        #expect(TerminalInjector.commands(for: ref, text: "answer").isEmpty)
    }
}
