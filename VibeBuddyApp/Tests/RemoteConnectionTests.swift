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
