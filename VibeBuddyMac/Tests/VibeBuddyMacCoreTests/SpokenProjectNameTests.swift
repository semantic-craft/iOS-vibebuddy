import Foundation
import Testing
@testable import VibeBuddyMacCore

struct SpokenProjectNameTests {
    @Test("a worktree is read aloud as its main checkout, in words", arguments: [false, true])
    func worktreeResolvesToMainCheckout(relative: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let main = root.appendingPathComponent("iOS-vibebuddy")
        let worktree = main.appendingPathComponent(".claude/worktrees/claude-code-vibebuddy-display-d51a8d")
        let gitDir = main.appendingPathComponent(".git/worktrees/claude-code-vibebuddy-display-d51a8d")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "../..\n".write(to: gitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let pointer = relative ? "../../../.git/worktrees/claude-code-vibebuddy-display-d51a8d" : gitDir.path
        try "gitdir: \(pointer)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(SpokenProjectName.resolve(checkoutPath: worktree.appendingPathComponent("Sources").path,
                                          fallback: "claude-code-vibebuddy-display-d51a8d") == "iOS vibebuddy")
        #expect(SpokenProjectName.resolve(checkoutPath: main.path, fallback: "x") == "iOS vibebuddy")
    }

    @Test("names without a checkout stay readable and placeholders yield nothing")
    func fallbacks() {
        #expect(SpokenProjectName.resolve(checkoutPath: "/nowhere/my_app", fallback: "my_app") == "my app")
        #expect(SpokenProjectName.resolve(checkoutPath: nil, fallback: "/nowhere/feature-login-d51a8d") == "feature login")
        #expect(SpokenProjectName.resolve(checkoutPath: nil, fallback: "—") == nil)
        #expect(SpokenProjectName.speakable("app-2024", trimTag: false) == "app 2024")
        #expect(SpokenProjectName.isMentioned("iOS vibebuddy", in: "iOS VibeBuddy finished the change."))
    }
}
