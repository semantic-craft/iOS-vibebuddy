import CoreServices
import Foundation
import XCTest
@testable import VibeBuddyMacCore

@MainActor
final class HistoryDirectoryWatcherTests: XCTestCase {
    func testFileAppendIsIncrementalAndStopSuppressesEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try Data("first".utf8).write(to: file)
        // Let creation events settle before observing an ordinary append.
        try await Task.sleep(for: .milliseconds(300))
        let received = expectation(description: "native append")
        var batches: [HistorySourceChanges] = []
        let watcher = HistoryDirectoryWatcher(roots: [root], settleDelay: .milliseconds(100)) { changes in
            batches.append(changes)
            if changes.paths.contains(file.resolvingSymlinksInPath().path), batches.count == 1 { received.fulfill() }
        }
        try await Task.sleep(for: .milliseconds(200))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" appended".utf8)); try handle.close()
        await fulfillment(of: [received], timeout: 5)
        XCTAssertFalse(batches.contains(where: \.requiresReconciliation))
        watcher.stop()
        let count = batches.count
        try Data("replacement".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(batches.count, count)
    }

    func testDroppedEventsAndOverflowRequestReconciliation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var batches: [HistorySourceChanges] = []
        let watcher = HistoryDirectoryWatcher(roots: [root], settleDelay: .milliseconds(20), pathLimit: 2) { batches.append($0) }
        defer { watcher.stop() }
        let path = root.resolvingSymlinksInPath().path
        watcher.receive(path: path + "/a.jsonl", flags: UInt32(kFSEventStreamEventFlagItemModified))
        watcher.receive(path: path + "/b.jsonl", flags: UInt32(kFSEventStreamEventFlagItemModified))
        watcher.receive(path: path + "/c.jsonl", flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(batches.count, 1)
        XCTAssertTrue(batches[0].requiresReconciliation)
        XCTAssertEqual(batches[0].paths.count, 2)
        watcher.receive(path: path + "/a.jsonl", flags: UInt32(kFSEventStreamEventFlagItemModified))
        watcher.receive(path: path, flags: UInt32(kFSEventStreamEventFlagUserDropped))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches[1].requiresReconciliation)
        XCTAssertEqual(batches[1].paths, [path + "/a.jsonl"])
    }

    func testContinuousEventsHaveBoundedWaitAndDeduplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var batches: [HistorySourceChanges] = []
        let watcher = HistoryDirectoryWatcher(roots: [root], settleDelay: .milliseconds(200), maximumDelay: .milliseconds(100)) { batches.append($0) }
        defer { watcher.stop() }
        let path = root.resolvingSymlinksInPath().appendingPathComponent("a.jsonl").path
        for _ in 0..<8 {
            watcher.receive(path: path, flags: UInt32(kFSEventStreamEventFlagItemModified))
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(batches.isEmpty)
        XCTAssertEqual(batches[0].paths, [path])
        XCTAssertFalse(batches[0].requiresReconciliation)
    }

    func testRenamedRootReplacementRemainsObserved() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = root.appendingPathComponent("session.jsonl")
        try Data("original".utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(300))
        let reset = expectation(description: "root change reconciles")
        let appended = expectation(description: "new root append remains incremental")
        var sawReset = false
        var waitingForAppend = false
        var sawAppend = false
        let watcher = HistoryDirectoryWatcher(roots: [root], settleDelay: .milliseconds(100)) { changes in
            if changes.requiresReconciliation, !sawReset {
                sawReset = true
                reset.fulfill()
            }
            if waitingForAppend, !changes.requiresReconciliation,
               changes.paths.contains(file.resolvingSymlinksInPath().path), !sawAppend {
                sawAppend = true
                appended.fulfill()
            }
        }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("old-sessions"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: file)
        await fulfillment(of: [reset], timeout: 5)
        try await Task.sleep(for: .milliseconds(400))
        waitingForAppend = true
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" appended".utf8)); try handle.close()
        await fulfillment(of: [appended], timeout: 5)
    }

    func testInitiallyMissingRootIsDiscovered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recovered = expectation(description: "missing root appears")
        var fulfilled = false
        let watcher = HistoryDirectoryWatcher(roots: [root], settleDelay: .milliseconds(20)) { changes in
            if changes.requiresReconciliation, !fulfilled { fulfilled = true; recovered.fulfill() }
        }
        defer { watcher.stop() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await fulfillment(of: [recovered], timeout: 5)
    }
}
