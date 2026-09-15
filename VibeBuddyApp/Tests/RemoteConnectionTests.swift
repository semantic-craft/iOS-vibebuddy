import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

final class RemoteConnectionTests: XCTestCase {
    private let pairing = PairingPayload(host: "100.64.0.8", port: 18765, token: "fixture")

    func testRequiresAuthenticatedSnapshotAndClosesProbe() async throws {
        let closed = expectation(description: "probe unsubscribed")
        _ = try await RemoteConnectionCheck.verify(pairing, streamer: ProbeStream { closed.fulfill() })
        await fulfillment(of: [closed], timeout: 2)
    }

    func testEmptyStreamDoesNotCountAsConnected() async {
        do {
            _ = try await RemoteConnectionCheck.verify(pairing, streamer: EmptyStreamer())
            XCTFail("A stream without a snapshot must not replace the saved address")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }

    func testAuthenticationErrorIsPreserved() async {
        do {
            _ = try await RemoteConnectionCheck.verify(pairing, streamer: RejectedStream())
            XCTFail("A rejected pairing must fail the probe")
        } catch {
            guard case CompanionConnectionFailure.authentication = error else {
                return XCTFail("Expected authentication failure")
            }
        }
    }

    /// Opt-in acceptance against the isolated daemon, using the actual iOS
    /// URLSession/WebSocket stack and a real agent session observed by the Mac.
    func testLivePrivateAddressWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VIBEBUDDY_QA_HOST"],
              let port = env["VIBEBUDDY_QA_PORT"].flatMap(Int.init), port != 9876,
              let token = env["VIBEBUDDY_QA_TOKEN"],
              let sessionID = env["VIBEBUDDY_QA_SESSION"] else {
            throw XCTSkip("Requires an isolated daemon with a real agent session")
        }
        let target = PairingPayload(host: host, port: port, token: token)
        let snapshot = try await RemoteConnectionCheck.verify(target)
        XCTAssertTrue(snapshot.sessions.contains { $0.id == sessionID })
        var rejected = target
        rejected.token += "-wrong"
        do {
            _ = try await RemoteConnectionCheck.verify(rejected)
            XCTFail("The live companion must reject the wrong pairing")
        } catch {
            guard case CompanionConnectionFailure.authentication = error else {
                return XCTFail("Expected live authentication refusal")
            }
        }
    }
}

private struct ProbeStream: SnapshotStreaming {
    let closed: @Sendable () -> Void
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in closed() }
            continuation.yield(Snapshot(sessions: [], serverTime: Date()))
        }
    }
}

private struct RejectedStream: SnapshotStreaming {
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> {
        AsyncThrowingStream { $0.finish(throwing: CompanionConnectionFailure.authentication) }
    }
}

@MainActor
final class RemoteConnectionAttemptTests: XCTestCase {
    func testRejectedCandidateKeepsSavedPairing() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let connection = ConnectionStore(defaults: defaults)
        let original = PairingPayload(host: "192.168.1.20", port: 9876, token: "old")
        connection.save(original)
        let check = RemoteConnectionAttempt()
        check.start(PairingPayload(host: "100.64.0.8", port: 9876, token: "new"),
                    connection: connection, streamer: RejectedStream())
        try await waitUntil { !check.isChecking }
        XCTAssertEqual(check.phase, .failure(.authentication))
        XCTAssertEqual(connection.pairing, original)
        XCTAssertEqual(try JSONDecoder().decode(PairingPayload.self, from: XCTUnwrap(defaults.data(forKey: "vibebuddy.pairing"))), original)
    }

    func testCancelledCheckCannotSaveOrClearReplacementCheck() async throws {
        let connection = ConnectionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let original = PairingPayload(host: "192.168.1.20", port: 9876, token: "old")
        connection.save(original)
        let first = HeldRemoteStream()
        let second = HeldRemoteStream()
        let check = RemoteConnectionAttempt()
        check.start(PairingPayload(host: "100.64.0.8", port: 9876, token: "first"), connection: connection, streamer: first)
        try await waitUntil { first.started }
        check.cancel()
        XCTAssertEqual(connection.pairing, original)
        let replacement = PairingPayload(host: "100.64.0.9", port: 9876, token: "replacement", macName: "Second Mac")
        check.start(replacement, connection: connection, streamer: second)
        try await waitUntil { second.started }
        first.deliver()
        await Task.yield()
        XCTAssertTrue(check.isChecking)
        XCTAssertEqual(connection.pairing, original)
        second.deliver()
        try await waitUntil { !check.isChecking }
        XCTAssertEqual(check.phase, .success)
        XCTAssertEqual(connection.pairing, replacement)
    }

    func testSavedPairingChangeDuringCheckIsNotOverwritten() async throws {
        let connection = ConnectionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let stream = HeldRemoteStream()
        let check = RemoteConnectionAttempt()
        check.start(PairingPayload(host: "100.64.0.8", port: 9876, token: "candidate"), connection: connection, streamer: stream)
        try await waitUntil { stream.started }
        let other = PairingPayload(host: "192.168.1.21", port: 9876, token: "other")
        connection.save(other)
        stream.deliver()
        try await waitUntil { !check.isChecking }
        XCTAssertEqual(check.phase, .failure(.pairingChanged))
        XCTAssertEqual(connection.pairing, other)
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Remote connection attempt did not finish")
    }
}

private final class HeldRemoteStream: SnapshotStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Snapshot, Error>.Continuation?
    var started: Bool { lock.withLock { continuation != nil } }

    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func deliver() {
        lock.withLock {
            continuation?.yield(Snapshot(sessions: [], serverTime: Date()))
            continuation?.finish()
        }
    }
}
