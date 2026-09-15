import XCTest
@testable import VibeBuddyKit

@MainActor
final class CompletionBodyReaderTests: XCTestCase {
    private func refresh(round: String = "one", attempt: Int = 0, active: Bool = true,
                         hint: String? = nil, context: String = "connection") -> CompletionBodyRefresh {
        var session = AgentSession(id: "task", agent: .codex, project: "QA", status: .done,
                                   statusSince: Date(), updatedAt: Date())
        session.completionID = round
        session.completionText = hint
        return CompletionBodyRefresh(sourceID: "mac", session: session, context: context,
                                     attempt: attempt, isActive: active)
    }
    private func body(_ text: String? = nil, round: String = "one") -> CompletionBody {
        CompletionBody(sourceID: "mac", sessionID: "task", completionID: round,
                       text: text, unavailableReason: text == nil ? "Not yet available" : nil)
    }

    func testLateBodyWithUnchangedIdentityAppearsAndUnavailableRetriesAreBounded() async {
        let reader = CompletionBodyReader()
        let key = refresh()
        var calls = 0
        await reader.load(key, retryDelays: [.zero, .zero]) {
            calls += 1
            return calls == 3 ? self.body("Late final") : self.body()
        }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(reader.body(for: key)?.text, "Late final")
        let missing = refresh(round: "missing")
        calls = 0
        await reader.load(missing, retryDelays: [.zero, .zero]) {
            calls += 1
            return self.body(round: "missing")
        }
        XCTAssertEqual(calls, 3)
        XCTAssertNotNil(reader.body(for: missing)?.unavailableReason)
        let retry = refresh(round: "missing", attempt: 1)
        await reader.load(retry) { self.body("Found after retry", round: "missing") }
        XCTAssertEqual(reader.body(for: retry)?.text, "Found after retry")
    }

    func testNetworkFailureEndsLoadingAndForegroundOrExplicitRetryCanRecover() async {
        let reader = CompletionBodyReader()
        var key = refresh()
        await reader.load(key) { nil }
        XCTAssertEqual(reader.state(for: key), .failed)
        key = refresh(attempt: 1)
        await reader.load(key) { self.body("Recovered") }
        XCTAssertEqual(reader.body(for: key)?.text, "Recovered")
        key = refresh(active: false)
        await reader.load(key) { XCTFail("No background request"); return nil }
        key = refresh(active: true)
        await reader.load(key) { XCTFail("Keep the already loaded exact result while offline"); return nil }
        XCTAssertEqual(reader.body(for: key)?.text, "Recovered")
        let failedReader = CompletionBodyReader()
        await failedReader.load(refresh(active: false)) { XCTFail("No background request"); return nil }
        await failedReader.load(key) { self.body("Recovered on foreground") }
        XCTAssertEqual(failedReader.body(for: key)?.text, "Recovered on foreground")
    }

    func testNewRoundOrConnectionHidesOldBodyAndLateResponseCannotReplaceNewRequest() async {
        let reader = CompletionBodyReader()
        let first = refresh()
        var continuation: CheckedContinuation<CompletionBody?, Never>?
        let pending = Task {
            await reader.load(first) { await withCheckedContinuation { continuation = $0 } }
        }
        while continuation == nil { await Task.yield() }
        let next = refresh(round: "two")
        await reader.load(next) { self.body("New round", round: "two") }
        continuation?.resume(returning: body("Old round"))
        await pending.value
        XCTAssertEqual(reader.body(for: next)?.text, "New round")
        XCTAssertNil(reader.body(for: first))
        XCTAssertNil(reader.body(for: refresh(round: "two", context: "repaired")))
    }

    func testSameRoundRetryWinsOverOlderInFlightRequestAndWrongIdentityFails() async {
        let reader = CompletionBodyReader()
        let first = refresh()
        var continuation: CheckedContinuation<CompletionBody?, Never>?
        let pending = Task {
            await reader.load(first) { await withCheckedContinuation { continuation = $0 } }
        }
        while continuation == nil { await Task.yield() }
        let retry = refresh(attempt: 1)
        await reader.load(retry) { self.body("Final") }
        continuation?.resume(returning: body())
        await pending.value
        XCTAssertEqual(reader.body(for: retry)?.text, "Final")
        let next = refresh(round: "two")
        await reader.load(next) { self.body("Wrong round") }
        XCTAssertEqual(reader.state(for: next), .failed)
    }

    func testOnlyMeaningfulHintsChangeRefreshKey() {
        XCTAssertEqual(refresh(), refresh())
        XCTAssertNotEqual(refresh(), refresh(hint: "Recovered"))
        XCTAssertNotEqual(refresh(), refresh(attempt: 1))
        XCTAssertNotEqual(refresh(), refresh(active: false))
    }
}
