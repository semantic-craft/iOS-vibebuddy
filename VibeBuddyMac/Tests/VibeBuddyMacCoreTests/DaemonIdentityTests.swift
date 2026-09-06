import Foundation
import Testing
@testable import VibeBuddyMacCore

struct DaemonIdentityTests {
    @Test("Daemon restarts reuse persisted identity and snapshots carry it")
    func persistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source-id")
        let first = try #require(DaemonIdentity.load(url: url))
        #expect(DaemonIdentity.load(url: url) == first)
        let store = SessionStore(sourceID: first)
        let snapshot = await store.snapshot(now: Date())
        #expect(snapshot.sourceID == first)
    }
}
