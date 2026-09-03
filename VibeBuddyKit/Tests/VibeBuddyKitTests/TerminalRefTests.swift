import Testing
import Foundation
@testable import VibeBuddyKit

/// `TerminalRef` is the wire shape of the `/terminal` hook payload as well as a
/// field of `AgentSession`, so its snake_case keys are load-bearing in both
/// directions.
@Suite("TerminalRef — the capture hook's payload")
struct TerminalRefTests {

    private func decode(_ json: String) throws -> TerminalRef {
        try JSONDecoder().decode(TerminalRef.self, from: Data(json.utf8))
    }

    @Test("every captured field decodes from the hook's snake_case payload")
    func decodesFullPayload() throws {
        let ref = try decode("""
        {"session_id":"s","term_program":"iTerm.app","tty":"ttys003",
         "tmux":"/tmp/tmux-501/default,1,0","tmux_pane":"%3",
         "iterm_session_id":"9C1E2E1E-0F3A-4B6D-9A11-2B7C4D5E6F70","wezterm_pane":"4",
         "kitty_window_id":"9","kitty_listen_on":"unix:/tmp/k","ghostty_terminal_id":"7",
         "host_bundle_id":"com.googlecode.iterm2","host_pid":4242,"cwd":"/Users/x/p"}
        """)
        #expect(ref.termProgram == "iTerm.app")
        #expect(ref.tty == "ttys003")
        #expect(ref.tmux == "/tmp/tmux-501/default,1,0")
        #expect(ref.tmuxPane == "%3")
        #expect(ref.itermSessionId == "9C1E2E1E-0F3A-4B6D-9A11-2B7C4D5E6F70")
        #expect(ref.weztermPane == "4")
        #expect(ref.kittyWindowId == "9")
        #expect(ref.kittyListenOn == "unix:/tmp/k")
        #expect(ref.ghosttyTerminalId == "7")
        #expect(ref.hostBundleId == "com.googlecode.iterm2")
        #expect(ref.hostPid == 4242)
        #expect(ref.cwd == "/Users/x/p")
    }

    @Test("an empty string is absence — shells find it easier to send \"\" than to omit a key")
    func emptyStringsAreNil() throws {
        let ref = try decode(#"{"term_program":"","tty":"","tmux":"","host_bundle_id":""}"#)
        #expect(ref.termProgram == nil)
        #expect(ref.tty == nil)
        #expect(ref.tmux == nil)
        #expect(ref.hostBundleId == nil)
        #expect(!ref.hasExactTarget)
    }

    @Test("a payload with nothing but a host bundle id is still a valid ref")
    func hostOnly() throws {
        let ref = try decode(#"{"host_bundle_id":"com.anthropic.claude-code","host_pid":99}"#)
        #expect(ref.termProgram == nil)
        #expect(ref.hostBundleId == "com.anthropic.claude-code")
        #expect(ref.hostPid == 99)
        #expect(!ref.hasExactTarget)
    }

    @Test("hasExactTarget is true for any pane/surface handle, one at a time",
          arguments: [
            #"{"tmux_pane":"%3"}"#,
            #"{"iterm_session_id":"UUID"}"#,
            #"{"wezterm_pane":"4"}"#,
            #"{"kitty_window_id":"9"}"#,
            #"{"ghostty_terminal_id":"7"}"#,
          ])
    func exactTargets(_ json: String) throws {
        #expect(try decode(json).hasExactTarget)
    }

    /// Terminal.app and iTerm2 are the only emulators whose dictionary exposes a
    /// tab's `tty`, so they are the only ones where a bare tty locates a
    /// surface. Everywhere else the tty is real but unaddressable, and claiming
    /// an exact target would promise a precision the jump can't deliver.
    @Test("a bare tty is an exact target only under Terminal.app and iTerm2",
          arguments: [
            (#"{"tty":"ttys003","term_program":"apple_terminal"}"#, true),
            (#"{"tty":"ttys003","term_program":"Apple_Terminal"}"#, true),
            (#"{"tty":"ttys003","term_program":"iTerm.app"}"#, true),
            (#"{"tty":"ttys003","host_bundle_id":"com.apple.Terminal"}"#, true),
            (#"{"tty":"ttys003","host_bundle_id":"com.googlecode.iterm2"}"#, true),
            (#"{"tty":"ttys003","term_program":"ghostty"}"#, false),
            (#"{"tty":"ttys003","term_program":"vscode"}"#, false),
            (#"{"tty":"ttys003","term_program":"WezTerm"}"#, false),
            (#"{"tty":"ttys003"}"#, false),
          ])
    func bareTTY(_ json: String, _ expected: Bool) throws {
        #expect(try decode(json).hasExactTarget == expected)
    }

    @Test("cwd alone is not an exact target — it's a hint, and several sessions can share it")
    func cwdIsNotATarget() throws {
        #expect(try !decode(#"{"cwd":"/Users/x/p","term_program":"ghostty"}"#).hasExactTarget)
    }

    /// What the `/terminal` route uses to decide whether a ref is worth storing.
    @Test("isActionable needs an exact target, a TERM_PROGRAM, or a host bundle id",
          arguments: [
            (#"{"cwd":"/Users/x/p"}"#, false),
            (#"{"tty":"ttys003"}"#, false),          // unaddressable without an emulator
            (#"{}"#, false),
            (#"{"term_program":"ghostty"}"#, true),
            (#"{"host_bundle_id":"com.anthropic.claude-code"}"#, true),
            (#"{"tmux_pane":"%3"}"#, true),
          ])
    func actionable(_ json: String, _ expected: Bool) throws {
        #expect(try decode(json).isActionable == expected)
    }

    /// Re-capture is not idempotent: `UserPromptSubmit` skips the Ghostty
    /// AppleScript probe, so merging is what keeps the terminal id alive.
    @Test("merging keeps what the newer capture couldn't see and takes what it could")
    func merges() {
        let first = TerminalRef(termProgram: "ghostty", tty: "ttys003",
                                ghosttyTerminalId: "42", hostBundleId: "com.mitchellh.ghostty",
                                hostPid: 100, cwd: "/x/p")
        let second = TerminalRef(termProgram: "ghostty", tty: "ttys009", cwd: "/x/q")
        let merged = first.merging(second)
        #expect(merged.ghosttyTerminalId == "42")
        #expect(merged.hostBundleId == "com.mitchellh.ghostty")
        #expect(merged.hostPid == 100)
        #expect(merged.tty == "ttys009")
        #expect(merged.cwd == "/x/q")
        // Merging an empty ref changes nothing at all.
        #expect(first.merging(TerminalRef()) == first)
    }

    @Test("round-trips through its own encoder, omitting what wasn't captured")
    func roundTrips() throws {
        let ref = TerminalRef(termProgram: "ghostty", ghosttyTerminalId: "7", cwd: "/Users/x/p")
        let data = try JSONEncoder().encode(ref)
        #expect(try decode(String(decoding: data, as: UTF8.self)) == ref)
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["term_program", "ghostty_terminal_id", "cwd"])
    }
}
