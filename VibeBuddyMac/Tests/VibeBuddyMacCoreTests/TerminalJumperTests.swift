import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("TerminalJumper.commands")
struct TerminalJumperTests {
    @Test("tmux ref → switch/select tmux argv (socket parsed) + open the app")
    func tmux() {
        let ref = TerminalRef(termProgram: "ghostty", tty: "ttys003", tmux: "/tmp/tmux-501/default,1234,0", tmuxPane: "%3")
        let c = TerminalJumper.commands(for: ref)
        #expect(c.contains(["/usr/bin/tmux", "-S", "/tmp/tmux-501/default", "select-pane", "-t", "%3"]))
        #expect(c.contains(["/usr/bin/tmux", "-S", "/tmp/tmux-501/default", "switch-client", "-t", "%3"]))
        #expect(c.last == ["/usr/bin/open", "-a", "Ghostty"])
    }
    @Test("no tmux → just activate the app")
    func noTmux() {
        #expect(TerminalJumper.commands(for: TerminalRef(termProgram: "iTerm.app")) == [["/usr/bin/open", "-a", "iTerm"]])
    }
    @Test("unknown term program → no commands")
    func unknown() {
        #expect(TerminalJumper.commands(for: TerminalRef(termProgram: "mystery")).isEmpty)
    }
}
