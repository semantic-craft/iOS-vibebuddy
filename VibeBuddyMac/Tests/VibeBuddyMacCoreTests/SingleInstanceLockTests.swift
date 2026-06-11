import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("SingleInstanceLock")
struct SingleInstanceLockTests {
    @Test("second acquire of the same lock returns nil until the first lock releases")
    func preventsSecondAcquire() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lockFile = dir.appendingPathComponent("mac-app.lock")

        do {
            let firstCandidate = try SingleInstanceLock.acquire(lockFileURL: lockFile)
            let first = try #require(firstCandidate)
            let second = try? SingleInstanceLock.acquire(lockFileURL: lockFile)
            #expect(second == nil)
            withExtendedLifetime(first) {}
        }

        let afterReleaseCandidate = try SingleInstanceLock.acquire(lockFileURL: lockFile)
        let afterRelease = try #require(afterReleaseCandidate)
        withExtendedLifetime(afterRelease) {}
    }
}
