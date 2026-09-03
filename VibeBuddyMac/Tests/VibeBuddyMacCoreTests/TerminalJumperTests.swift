import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// The planner is the whole of the jump's decision-making, and it is pure — these
/// tests cover which commands *would* run without launching anything.
@Suite("TerminalJumper.plan")
struct TerminalJumperTests {

    // Fixed tool paths so a plan doesn't depend on what happens to be installed.
    private static let tmux = "/opt/homebrew/bin/tmux"
    private static let wezterm = "/opt/homebrew/bin/wezterm"
    private static let kitten = "/opt/homebrew/bin/kitten"

    private func plan(_ ref: TerminalRef,
                      wezterm: String? = TerminalJumperTests.wezterm,
                      kitten: String? = TerminalJumperTests.kitten) -> JumpPlan {
        TerminalJumper.plan(for: ref, tmuxPath: Self.tmux, weztermPath: wezterm, kittenPath: kitten)
    }

    /// The AppleScript source of the nth surface attempt.
    private func script(_ plan: JumpPlan, _ index: Int) -> String {
        let argv = plan.surface[index].commands[0]
        #expect(argv[0] == "/usr/bin/osascript")
        #expect(argv[1] == "-e")
        return argv[2]
    }

    // MARK: tmux

    @Test("a tmux pane is selected, unzoomed only when zoomed, and its terminal raised")
    func tmuxPane() {
        let p = plan(TerminalRef(termProgram: "ghostty", tmux: "/tmp/tmux-501/default,1234,0", tmuxPane: "%3"))
        #expect(p.tmux == [
            TmuxStep(argv: [Self.tmux, "-S", "/tmp/tmux-501/default", "switch-client", "-t", "%3"], focuses: true),
            TmuxStep(argv: [Self.tmux, "-S", "/tmp/tmux-501/default", "select-window", "-t", "%3"], focuses: true),
            TmuxStep(argv: [Self.tmux, "-S", "/tmp/tmux-501/default", "if-shell", "-F", "-t", "%3",
                            "#{window_zoomed_flag}", "resize-pane -Z -t %3"], focuses: false),
            TmuxStep(argv: [Self.tmux, "-S", "/tmp/tmux-501/default", "select-pane", "-t", "%3"], focuses: false),
        ])
        // The outer terminal is still brought forward: selecting a pane in a
        // background window is not a jump.
        #expect(p.activateBundleID == "com.mitchellh.ghostty")
    }

    @Test("a pane id that isn't %N is refused")
    func tmuxPaneRejected() {
        #expect(plan(TerminalRef(tmux: "/tmp/x,1,0", tmuxPane: "3")).tmux.isEmpty)
        #expect(plan(TerminalRef(tmux: "/tmp/x,1,0", tmuxPane: "%3; rm -rf /")).tmux.isEmpty)
        #expect(plan(TerminalRef(tmux: "", tmuxPane: "%3")).tmux.isEmpty)
    }

    @Test("a $TMUX socket that isn't an absolute path is refused")
    func tmuxSocketRejected() {
        for bad in ["default,1,0", "-S,1,0", "--socket,1,0", ",1,0"] {
            #expect(plan(TerminalRef(tmux: bad, tmuxPane: "%3")).tmux.isEmpty, "accepted \(bad)")
        }
        #expect(TerminalJumper.tmuxSocket("/tmp/tmux-501/default,1,0") == "/tmp/tmux-501/default")
    }

    /// `select-pane` succeeds just as happily against a buried window, so it is
    /// not on its own evidence that the user was taken anywhere.
    @Test("only the steps that move the viewport are marked as focusing")
    func tmuxFocusingSteps() {
        let p = plan(TerminalRef(tmux: "/tmp/x,1,0", tmuxPane: "%3"))
        #expect(p.tmux.filter(\.focuses).map { $0.argv[3] } == ["switch-client", "select-window"])
        #expect(p.tmux.filter { !$0.focuses }.map { $0.argv[3] } == ["if-shell", "select-pane"])
    }

    // MARK: Terminal.app

    @Test("Apple Terminal is targeted by the tab's tty")
    func appleTerminal() {
        let p = plan(TerminalRef(termProgram: "Apple_Terminal", tty: "ttys003"))
        #expect(p.surface.count == 1)
        let s = script(p, 0)
        #expect(s.contains(#"tell application id "com.apple.Terminal""#))
        #expect(s.contains(#"if tty of t is "/dev/ttys003""#))
        #expect(p.activateBundleID == "com.apple.Terminal")
    }

    @Test("a tty already carrying /dev/ is accepted once, not twice")
    func ttyNormalized() {
        #expect(script(plan(TerminalRef(termProgram: "Apple_Terminal", tty: "/dev/ttys012")), 0)
            .contains(#""/dev/ttys012""#))
    }

    @Test("a tty that isn't ttysN never reaches AppleScript")
    func ttyRejected() {
        for bad in ["??", "console", "ttys003\" then activate", "ttys", "ttysX"] {
            #expect(plan(TerminalRef(termProgram: "Apple_Terminal", tty: bad)).surface.isEmpty,
                    "accepted \(bad)")
        }
    }

    // MARK: iTerm2

    @Test("iTerm2 tries the session's unique ID first, then its tty")
    func iterm() {
        let p = plan(TerminalRef(termProgram: "iTerm.app", tty: "ttys009",
                                 itermSessionId: "9C1E2E1E-0F3A-4B6D-9A11-2B7C4D5E6F70"))
        #expect(p.surface.count == 2)
        #expect(script(p, 0).contains(#"if unique ID of s is "9C1E2E1E-0F3A-4B6D-9A11-2B7C4D5E6F70""#))
        #expect(script(p, 1).contains(#"if tty of s is "/dev/ttys009""#))
        #expect(p.activateBundleID == "com.googlecode.iterm2")
    }

    @Test("an id carrying a quote or a newline is dropped, never escaped into the script")
    func idSanitized() {
        for bad in [#"abc" then do shell script "id"#, "abc\ndo shell script \"id\"", "abc def", "abc'x"] {
            let p = plan(TerminalRef(termProgram: "iTerm.app", itermSessionId: bad))
            #expect(p.surface.isEmpty, "accepted \(bad)")
        }
    }

    // MARK: Ghostty

    @Test("Ghostty tries its terminal id first and falls back to the working directory")
    func ghostty() {
        let p = plan(TerminalRef(termProgram: "ghostty", ghosttyTerminalId: "42", cwd: "/Users/x/p"))
        #expect(p.surface.count == 2)
        #expect(script(p, 0).contains(#"first terminal whose id is "42""#))
        #expect(script(p, 1).contains(#"first terminal whose working directory is "/Users/x/p""#))
    }

    @Test("without a terminal id the working directory is the only Ghostty target")
    func ghosttyCWDOnly() {
        let p = plan(TerminalRef(termProgram: "ghostty", cwd: "/Users/x/p"))
        #expect(p.surface.count == 1)
        #expect(script(p, 0).contains(#"working directory is "/Users/x/p""#))
    }

    @Test("a backslash in a path is doubled, so it can't escape the AppleScript literal")
    func ghosttyBackslashDoubled() {
        #expect(script(plan(TerminalRef(termProgram: "ghostty", cwd: #"/Users/x/a\b"#)), 0)
            .contains(#"working directory is "/Users/x/a\\b""#))
        // A trailing backslash is the dangerous one: undoubled it would escape
        // the closing quote and let the rest of the path become AppleScript.
        #expect(script(plan(TerminalRef(termProgram: "ghostty", cwd: #"/Users/x/a\"#)), 0)
            .contains(#"working directory is "/Users/x/a\\""#))
    }

    @Test("a quote in a path is escaped; a control character rejects it outright")
    func ghosttyPathSafety() {
        #expect(script(plan(TerminalRef(termProgram: "ghostty", cwd: #"/Users/x/a"b"#)), 0)
            .contains(#"working directory is "/Users/x/a\"b""#))
        #expect(plan(TerminalRef(termProgram: "ghostty", cwd: "/Users/x\nactivate")).surface.isEmpty)
        #expect(plan(TerminalRef(termProgram: "ghostty", cwd: "relative/path")).surface.isEmpty)
    }

    // MARK: WezTerm / kitty

    @Test("WezTerm activates the pane and its tab as one attempt")
    func wezterm() {
        let p = plan(TerminalRef(termProgram: "WezTerm", weztermPane: "7"))
        #expect(p.surface == [JumpAttempt([
            [Self.wezterm, "cli", "activate-pane", "--pane-id", "7"],
            [Self.wezterm, "cli", "activate-tab", "--pane-id", "7"],
        ])])
        #expect(p.activateBundleID == "com.github.wez.wezterm")
    }

    @Test("no wezterm binary installed → nothing below app level is planned")
    func weztermMissing() {
        let p = plan(TerminalRef(termProgram: "WezTerm", weztermPane: "7"), wezterm: nil)
        #expect(p.surface.isEmpty)
        #expect(p.activateBundleID == "com.github.wez.wezterm")
    }

    @Test("kitty is focused over its remote-control socket")
    func kitty() {
        let p = plan(TerminalRef(termProgram: "kitty", kittyWindowId: "3",
                                 kittyListenOn: "unix:/tmp/kitty-501"))
        #expect(p.surface == [JumpAttempt(
            [Self.kitten, "@", "--to", "unix:/tmp/kitty-501", "focus-window", "--match", "id:3"])])
        #expect(p.activateBundleID == "net.kovidgoyal.kitty")
    }

    @Test("kitty without a listen socket cannot be addressed, so it stops at the app")
    func kittyNoSocket() {
        let p = plan(TerminalRef(termProgram: "kitty", kittyWindowId: "3"))
        #expect(p.surface.isEmpty)
        #expect(p.activateBundleID == "net.kovidgoyal.kitty")
    }

    // MARK: app-level fallback

    @Test("an unknown TERM_PROGRAM still jumps to the host app that was captured")
    func unknownTermProgramWithHost() {
        let p = plan(TerminalRef(termProgram: "mystery", hostBundleId: "com.anthropic.claude-code"))
        #expect(p.surface.isEmpty)
        #expect(p.activateBundleID == "com.anthropic.claude-code")
    }

    @Test("no TERM_PROGRAM at all — an embedded terminal — is carried by the host bundle id")
    func embeddedTerminal() {
        let p = plan(TerminalRef(hostBundleId: "com.anthropic.claudefordesktop", hostPid: 4242))
        #expect(p.activateBundleID == "com.anthropic.claudefordesktop")
    }

    @Test("the captured host wins over the TERM_PROGRAM table, which can't tell Cursor from VS Code")
    func cursorVersusVSCode() {
        #expect(plan(TerminalRef(termProgram: "vscode",
                                 hostBundleId: "com.todesktop.230313mzl4w4u92")).activateBundleID
                == "com.todesktop.230313mzl4w4u92")
        #expect(plan(TerminalRef(termProgram: "vscode")).activateBundleID == "com.microsoft.VSCode")
    }

    @Test("the host bundle id also names the terminal family when TERM_PROGRAM is missing")
    func familyFromHostBundle() {
        let p = plan(TerminalRef(tty: "ttys004", hostBundleId: "com.apple.Terminal"))
        #expect(p.surface.count == 1)
        #expect(script(p, 0).contains(#""/dev/ttys004""#))
    }

    @Test("a session we know nothing about plans nothing at all")
    func empty() {
        #expect(plan(TerminalRef()).isEmpty)
        #expect(plan(TerminalRef(termProgram: "mystery")).isEmpty)
    }

    // MARK: the no-launch gate

    /// `tell application id "…"` launches the app when it isn't running, so
    /// every plan that scripts one has to say which app must already be up.
    @Test("every family that plans a surface attempt names the app that must be running",
          arguments: [
            (TerminalRef(termProgram: "Apple_Terminal", tty: "ttys003"), ["com.apple.Terminal"]),
            (TerminalRef(termProgram: "iTerm.app", tty: "ttys003"), ["com.googlecode.iterm2"]),
            (TerminalRef(termProgram: "ghostty", ghosttyTerminalId: "42"), ["com.mitchellh.ghostty"]),
            (TerminalRef(termProgram: "WezTerm", weztermPane: "7"), ["com.github.wez.wezterm"]),
            (TerminalRef(termProgram: "kitty", kittyWindowId: "3", kittyListenOn: "unix:/tmp/k"),
             ["net.kovidgoyal.kitty"]),
          ])
    func requiredRunningBundleIDs(_ ref: TerminalRef, _ expected: [String]) {
        let p = plan(ref)
        #expect(!p.surface.isEmpty)
        #expect(p.requiredRunningBundleIDs == expected)
    }

    @Test("a plan with nothing below app level requires nothing to be running")
    func noSurfaceNoRequirement() {
        #expect(plan(TerminalRef(termProgram: "vscode")).requiredRunningBundleIDs.isEmpty)
        #expect(plan(TerminalRef(tmux: "/tmp/x,1,0", tmuxPane: "%3")).requiredRunningBundleIDs.isEmpty)
    }

    /// `/usr/bin/true` stands in for a surface attempt that would certainly
    /// succeed, so a `.unsupported` verdict can only mean it was never run.
    @Test("the surface tier is skipped entirely when the emulator isn't running")
    func surfaceGatedOnRunningApp() {
        var p = JumpPlan()
        p.surface = [JumpAttempt(["/usr/bin/true"])]
        p.requiredRunningBundleIDs = ["com.example.terminal"]
        #expect(TerminalJumper.execute(p, isRunning: { _ in false }, activate: { _ in false })
                == .unsupported)
        #expect(TerminalJumper.execute(p, isRunning: { _ in true }, activate: { _ in false })
                == .focused)
    }

    /// A jump that can't reach the surface is still allowed to raise the app —
    /// it just has to say so, which is what `.activatedApp` means.
    @Test("a gated surface degrades the jump to the app, it doesn't abort it")
    func gatedSurfaceStillActivates() {
        var p = JumpPlan()
        p.surface = [JumpAttempt(["/usr/bin/true"])]
        p.requiredRunningBundleIDs = ["com.example.terminal"]
        p.activateBundleID = "com.example.terminal"
        #expect(TerminalJumper.execute(p, isRunning: { _ in false }, activate: { _ in true })
                == .activatedApp)
    }

    // MARK: outcome wiring

    @Test("a tmux step that only rearranges an off-screen window is not a focus")
    func tmuxNonFocusingStepIsNotAJump() {
        var p = JumpPlan()
        p.tmux = [TmuxStep(argv: ["/usr/bin/true"], focuses: false)]
        #expect(TerminalJumper.execute(p, isRunning: { _ in true }, activate: { _ in false })
                == .unsupported)
        p.tmux.append(TmuxStep(argv: ["/usr/bin/true"], focuses: true))
        #expect(TerminalJumper.execute(p, isRunning: { _ in true }, activate: { _ in false })
                == .focused)
    }

    @Test("an empty plan can only report unsupported")
    func emptyPlanOutcome() {
        #expect(TerminalJumper.execute(JumpPlan(), isRunning: { _ in true }, activate: { _ in false })
                == .unsupported)
    }
}
