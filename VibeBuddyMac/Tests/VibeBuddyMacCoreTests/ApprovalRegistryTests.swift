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

    @Test("resolving an unknown id is a harmless no-op")
    func unknownResolve() async {
        let reg = ApprovalRegistry()
        await reg.resolve(id: "ghost", with: .deny)   // must not crash
    }
}
