import Foundation
import Testing
@testable import VibeBuddyMacCore

struct SpokenProjectNameTests {
    @Test("a worktree is read aloud as its main checkout, in words")
    func worktreeResolvesToMainCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("iOS-vibebuddy")
        let worktree = main.appendingPathComponent(".claude/worktrees/claude-code-vibebuddy-display-d51a8d")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/claude-code-vibebuddy-display-d51a8d\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(SpokenProjectName.resolve(checkoutPath: worktree.appendingPathComponent("Sources").path,
                                          fallback: "claude-code-vibebuddy-display-d51a8d") == "iOS vibebuddy")
        #expect(SpokenProjectName.resolve(checkoutPath: main.path, fallback: "x") == "iOS vibebuddy")
        #expect(SpokenProjectName.resolve(checkoutPath: "/nowhere/my_app", fallback: "my_app") == "my app")
        #expect(SpokenProjectName.speakable("feature-login-d51a8d") == "feature login")
        #expect(SpokenProjectName.speakable("1884") == "1884")
    }
}
