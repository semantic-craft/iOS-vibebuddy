import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
final class PhoneHistoryTests: XCTestCase {
    private func page(_ range: Range<Int>, revision: String = "one") throws -> HistoryPage {
        let messages = try range.map { i in
            try JSONDecoder().decode(HistoryMessage.self, from: Data("{\"id\":\"m\(i)\",\"role\":\"user\",\"text\":\"message \(i)\"}".utf8))
        }
        return HistoryPage(sourceID: "mac", key: "codex:task", revision: revision, messages: messages,
            start: range.lowerBound, end: range.upperBound, totalMessages: 65,
            nextCursor: range.lowerBound > 0 ? "cursor" : nil, coverage: "parsed-visible", sourceLimitReached: false, warnings: [])
    }
    private func finish(_ reader: PhoneHistoryReader) async throws {
        for _ in 0..<100 where reader.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(reader.loading)
    }
    func testPrependAndStagedRevisionDoNotMoveReadingUntilSelected() async throws {
        let reader = PhoneHistoryReader()
        reader.load { _ in try self.page(35..<65) }; try await finish(reader)
        let beforePaging = reader.scrollRevision
        reader.load(earlier: true) { cursor in XCTAssertEqual(cursor, "cursor"); return try self.page(5..<35) }
        try await finish(reader)
        XCTAssertEqual(reader.messages.count, 60); XCTAssertEqual(reader.scrollRevision, beforePaging)
        let scroll = reader.scrollRevision
        reader.load { _ in try self.page(35..<65, revision: "two") }; try await finish(reader)
        XCTAssertEqual(reader.messages.count, 60); XCTAssertEqual(reader.page?.revision, "one")
        XCTAssertEqual(reader.scrollRevision, scroll); XCTAssertFalse(reader.hasEarlier)
        reader.showPending()
        XCTAssertEqual(reader.messages.count, 30); XCTAssertEqual(reader.page?.revision, "two")
        XCTAssertEqual(reader.scrollTarget, "m64")
    }
    func testOfflinePreservesContentAndExpiredCursorCannotAppend() async throws {
        let reader = PhoneHistoryReader()
        reader.load { _ in try self.page(35..<65) }; try await finish(reader)
        reader.load { _ in throw HistoryFailure("source_unavailable") }; try await finish(reader)
        XCTAssertEqual(reader.messages.count, 30)
        reader.load(earlier: true) { _ in throw HistoryFailure("cursor_expired") }; try await finish(reader)
        XCTAssertFalse(reader.hasEarlier); XCTAssertEqual(reader.messages.count, 30)
        reader.load { _ in try self.page(35..<65) }; try await finish(reader)
        XCTAssertNotNil(reader.pending)
        reader.showPending(); XCTAssertTrue(reader.hasEarlier)
    }
    func testInvalidatedRequestCannotRestoreOtherSource() async throws {
        let reader = PhoneHistoryReader()
        var release: CheckedContinuation<HistoryPage, Never>?
        reader.load { _ in await withCheckedContinuation { release = $0 } }
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(release)
        reader.cancel(clear: true)
        release?.resume(returning: try page(35..<65))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(reader.messages.isEmpty); XCTAssertNil(reader.page)
    }
}
