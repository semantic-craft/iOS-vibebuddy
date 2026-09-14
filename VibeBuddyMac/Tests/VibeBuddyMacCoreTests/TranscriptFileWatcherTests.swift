import Foundation
import XCTest
@testable import VibeBuddyMacCore

@MainActor
final class TranscriptFileWatcherTests: XCTestCase {
    func testDelayedReplacementAndItsLaterAppendRemainObserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("transcript.jsonl")
        try Data("first".utf8).write(to: file)
        let replacement = expectation(description: "delayed replacement observed")
        let appended = expectation(description: "replacement remains watched")
        var sawReplacement = false
        var sawAppend = false
        let watcher = TranscriptFileWatcher(path: file.path) {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if text == "replacement", !sawReplacement { sawReplacement = true; replacement.fulfill() }
            if text == "replacement appended", !sawAppend { sawAppend = true; appended.fulfill() }
        }
        try FileManager.default.removeItem(at: file)
        // The original watcher tried to reopen only once after one second.
        try await Task.sleep(for: .milliseconds(1400))
        try Data("replacement".utf8).write(to: file)
        await fulfillment(of: [replacement], timeout: 4)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" appended".utf8)); try handle.close()
        await fulfillment(of: [appended], timeout: 4)
        withExtendedLifetime(watcher) {}
    }
}
