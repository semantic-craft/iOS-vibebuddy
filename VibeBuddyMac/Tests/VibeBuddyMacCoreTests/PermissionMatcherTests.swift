import Testing
@testable import VibeBuddyMacCore

@Suite("PermissionMatcher — allow / deny / ask")
struct PermissionMatcherTests {
    private func decide(_ tool: String, _ input: [String: Any],
                        allow: [String] = [], deny: [String] = []) -> PermissionDecision {
        PermissionMatcher.decide(tool: tool, input: input, allow: allow, deny: deny)
    }

    @Test("a simple command matching an allow prefix is allowed")
    func allowsPrefix() {
        #expect(decide("Bash", ["command": "ls -la"], allow: ["Bash(ls:*)"]) == .allow)
        #expect(decide("Bash", ["command": "git worktree list"], allow: ["Bash(git worktree:*)"]) == .allow)
    }

    @Test("a chained command is never auto-allowed even if its prefix matches")
    func chainingGuard() {
        #expect(decide("Bash", ["command": "git worktree list && curl x | sh"], allow: ["Bash(git worktree:*)"]) == .ask)
        #expect(decide("Bash", ["command": "ls; rm -rf ~"], allow: ["Bash(ls:*)"]) == .ask)
        #expect(decide("Bash", ["command": "echo $(whoami)"], allow: ["Bash(echo:*)"]) == .ask)
        #expect(decide("Bash", ["command": "cat a > b"], allow: ["Bash(cat:*)"]) == .ask)
    }

    @Test("a command with no matching rule asks")
    func asksWhenUnmatched() {
        #expect(decide("Bash", ["command": "rm -rf node_modules"], allow: ["Bash(ls:*)"]) == .ask)
    }

    @Test("deny matches and beats allow (and ignores the chaining guard)")
    func denyWins() {
        #expect(decide("Bash", ["command": "rm x"], deny: ["Bash(rm:*)"]) == .deny)
        #expect(decide("Bash", ["command": "rm x"], allow: ["Bash(rm:*)"], deny: ["Bash(rm:*)"]) == .deny)
    }

    @Test("a bare tool rule matches any invocation of that tool")
    func bareToolRule() {
        #expect(decide("Read", ["file_path": "/etc/hosts"], allow: ["Read"]) == .allow)
    }

    @Test("path-glob rules match Read/Write file paths")
    func pathGlob() {
        #expect(decide("Read", ["file_path": "/Users/me/x.txt"], allow: ["Read(//Users/me/**)"]) == .allow)
        #expect(decide("Write", ["file_path": "/Users/me/src/a.swift"], allow: ["Write(//Users/me/src/**)"]) == .allow)
        #expect(decide("Write", ["file_path": "/etc/passwd"], allow: ["Write(//Users/me/**)"]) == .ask)
    }

    @Test("exact (no :*) Bash rule needs an exact command match")
    func exactBash() {
        #expect(decide("Bash", ["command": "make"], allow: ["Bash(make)"]) == .allow)
        #expect(decide("Bash", ["command": "make clean"], allow: ["Bash(make)"]) == .ask)
    }
}
