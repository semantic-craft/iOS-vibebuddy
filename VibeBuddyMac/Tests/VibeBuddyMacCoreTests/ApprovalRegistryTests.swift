import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("ApprovalRegistry — hold until decision or timeout")
struct ApprovalRegistryTests {
    @Test("resolve before timeout returns that outcome")
    func resolves() async {
        let reg = ApprovalRegistry()
        async let outcome = reg.wait(id: "a", timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        await reg.resolve(id: "a", with: .allow)
        #expect(await outcome == .allow)
    }

    @Test("no decision before the timeout yields .pass")
    func timesOut() async {
        let reg = ApprovalRegistry()
        let outcome = await reg.wait(id: "b", timeout: .milliseconds(50))
        #expect(outcome == .pass)
    }

    @Test("a decision that beats its request is held for it")
    func resolveBeforeWait() async {
        let reg = ApprovalRegistry()
        await reg.prepare(id: "a")
        await reg.resolve(id: "a", with: .allow)
        #expect(await reg.wait(id: "a", timeout: .seconds(5)) == .allow)
        // Spent: the next hold on the same id waits on its own decision.
        #expect(await reg.wait(id: "a", timeout: .milliseconds(50)) == .pass)
    }
    @Test("expired and unknown approvals cannot be claimed or revived")
    func expiredCannotClaim() async {
        let reg = ApprovalRegistry()
        #expect(await reg.wait(id: "expired", timeout: .milliseconds(1)) == .pass)
        #expect(await reg.claim(id: "expired") == false)
        #expect(await reg.resolve(id: "expired", with: .allow) == false)
        #expect(await reg.claim(id: "unknown") == false)
    }

    @Test("a claimed decision wins timeout while permission effects complete")
    func claimBeforeTimeout() async {
        let reg = ApprovalRegistry()
        await reg.prepare(id: "a")
        #expect(await reg.claim(id: "a"))
        #expect(await reg.claim(id: "a") == false)
        async let outcome = reg.wait(id: "a", timeout: .milliseconds(1))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await reg.resolve(id: "a", with: .allow))
        #expect(await outcome == .allow)
    }
}
