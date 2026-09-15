import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
final class RemoteConnectionSyncTests: XCTestCase {
    private let original = PairingPayload(host: "192.168.1.20", port: 9876, token: "existing-authority", macName: "My Mac")
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testLiveHTTPProxyAndStableIdentityWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VIBEBUDDY_QA_HOST"],
              let port = env["VIBEBUDDY_QA_PORT"].flatMap(Int.init), port != 9876,
              let token = env["VIBEBUDDY_QA_TOKEN"], !token.isEmpty else {
            throw XCTSkip("Requires an isolated daemon through VIBEBUDDY_QA_HOST/PORT/TOKEN")
        }
        let identity = PushDeviceIdentity.current()
        print("Remote HTTP acceptance: stable device identity available = \(identity != nil)")
        XCTAssertNotNil(identity, "The native app must have a durable PushDeviceIdentity")
        XCTAssertEqual(PushDeviceIdentity.current(), identity, "Reading the identity again must preserve it")

        let pairing = PairingPayload(host: host, port: port, token: token)
        let url = try XCTUnwrap(pairing.endpoint?.url(path: "connection-sync", queryItems: [
            URLQueryItem(name: "deviceID", value: UUID().uuidString)
        ]))
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let directSession = URLSession(configuration: configuration)
        defer { directSession.invalidateAndCancel() }

        func probe(_ session: URLSession, label: String) async -> Int? {
            let started = Date()
            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                print("Remote HTTP acceptance: \(label), status = \(status.map(String.init) ?? "non-HTTP"), seconds = \(Date().timeIntervalSince(started))")
                return status
            } catch {
                let failure = error as NSError
                print("Remote HTTP acceptance: \(label), error = \(failure.domain)/\(failure.code), seconds = \(Date().timeIntervalSince(started))")
                return nil
            }
        }

        let sharedStatus = await probe(.shared, label: "shared")
        let directStatus = await probe(directSession, label: "ephemeral without proxy")
        XCTAssertEqual(sharedStatus, 403, "Shared HTTP must reach the daemon and reject the unknown device")
        XCTAssertEqual(directStatus, 403, "HTTP without a proxy must reach the same authenticated endpoint")
    }

    private func proposal() -> RemoteConnectionProposal {
        RemoteConnectionProposal(requestID: "request", deviceID: "phone", sourceID: "mac-source",
                                 host: "100.64.0.8", port: 18765, expiresAt: instant.addingTimeInterval(300))
    }

    private func connection() -> ConnectionStore {
        let connection = ConnectionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        connection.save(original)
        return connection
    }

    func testDifferentSnapshotSourceCannotReplacePairing() async {
        let connection = connection()
        let client = SyncFixtureClient(proposal: proposal())
        let stream = SyncFixtureStream(snapshot: Snapshot(sessions: [], serverTime: instant, sourceID: "other-mac"))
        let sync = RemoteConnectionSyncController(client: client, streamer: stream, deviceID: "phone", now: { self.instant })
        await sync.poll(connection: connection, currentSourceID: { nil })
        XCTAssertEqual(connection.pairing, original)
        XCTAssertEqual(sync.state, .failed(.wrongMac))
        let outcomes = await client.outcomes
        XCTAssertEqual(outcomes, [.received, .unauthorized])
    }

    func testConfirmedReceiptRetriesWithoutProbingOrSavingAgain() async {
        let connection = connection()
        let client = SyncFixtureClient(proposal: proposal(), failedConfirmations: 2)
        let stream = SyncFixtureStream(snapshot: Snapshot(sessions: [], serverTime: instant, sourceID: "mac-source"))
        let sync = RemoteConnectionSyncController(client: client, streamer: stream, deviceID: "phone", now: { self.instant })
        await sync.poll(connection: connection, currentSourceID: { "mac-source" })
        XCTAssertEqual(connection.pairing?.host, "100.64.0.8")
        XCTAssertEqual(connection.pairing?.token, original.token)
        XCTAssertEqual(sync.state, .connected(.pending))
        XCTAssertEqual(stream.calls, 1)
        sync.pause()
        await sync.poll(connection: connection, currentSourceID: { "mac-source" })
        XCTAssertEqual(sync.state, .connected(.confirmed))
        XCTAssertEqual(stream.calls, 1)
        let confirmations = await client.outcomes.filter { $0 == .confirmed }
        XCTAssertEqual(confirmations.count, 3)
    }

    func testRejectedConfirmationKeepsVerifiedAddressWithoutClaimingMacConfirmed() async {
        let connection = connection()
        let client = SyncFixtureClient(proposal: proposal(), rejectConfirmation: true)
        let stream = SyncFixtureStream(snapshot: Snapshot(sessions: [], serverTime: instant, sourceID: "mac-source"))
        let sync = RemoteConnectionSyncController(client: client, streamer: stream, deviceID: "phone", now: { self.instant })
        await sync.poll(connection: connection, currentSourceID: { "mac-source" })
        XCTAssertEqual(connection.pairing?.host, "100.64.0.8")
        XCTAssertEqual(sync.state, .connected(.unavailable))
        await sync.poll(connection: connection, currentSourceID: { "mac-source" })
        XCTAssertEqual(stream.calls, 1)
        let confirmations = await client.outcomes.filter { $0 == .confirmed }
        XCTAssertEqual(confirmations.count, 1)
    }

    func testReceiptFailureDoesNotHideWithdrawalOrKeepExpiredReceiptPending() async {
        for expire in [true, false] {
            let connection = connection()
            let client = SyncFixtureClient(proposal: proposal(), failedConfirmations: 100)
            let stream = SyncFixtureStream(snapshot: Snapshot(sessions: [], serverTime: instant, sourceID: "mac-source"))
            var clock = instant
            let sync = RemoteConnectionSyncController(client: client, streamer: stream, deviceID: "phone", now: { clock })
            await sync.poll(connection: connection, currentSourceID: { "mac-source" })
            XCTAssertEqual(sync.state, .connected(.pending))
            if expire { clock = instant.addingTimeInterval(301) }
            else { await client.setProposal(nil) }
            await sync.poll(connection: connection, currentSourceID: { "mac-source" })
            XCTAssertEqual(sync.state, .connected(.unavailable))
            XCTAssertEqual(connection.pairing?.host, "100.64.0.8")
            XCTAssertEqual(stream.calls, 1)
        }
    }

    func testDemoHidesPreviousMacUpdate() async {
        let connection = connection()
        let client = SyncFixtureClient(proposal: proposal())
        let stream = SyncFixtureStream(snapshot: Snapshot(sessions: [], serverTime: instant, sourceID: "mac-source"))
        let sync = RemoteConnectionSyncController(client: client, streamer: stream, deviceID: "phone", now: { self.instant })
        await sync.poll(connection: connection, currentSourceID: { "mac-source" })
        connection.enterDemo()
        await sync.run(connection: connection, enabled: true, currentSourceID: { nil })
        XCTAssertEqual(sync.state, .idle)
        XCTAssertNil(sync.address)
    }

    func testExpiredOrPausedProbeKeepsOriginalPairing() async throws {
        for expire in [true, false] {
            let connection = connection()
            let client = SyncFixtureClient(proposal: proposal())
            let stream = SyncFixtureStream()
            var clock = instant
            let sync = RemoteConnectionSyncController(client: client, streamer: stream, deviceID: "phone", now: { clock })
            let task = Task { await sync.poll(connection: connection, currentSourceID: { "mac-source" }) }
            try await waitUntil { stream.calls == 1 }
            if expire { clock = instant.addingTimeInterval(301) }
            else { sync.pause() }
            stream.deliver(Snapshot(sessions: [], serverTime: instant, sourceID: "mac-source"))
            await task.value
            XCTAssertEqual(connection.pairing, original)
            XCTAssertEqual(sync.state, .failed(expire ? .expired : .cancelled))
        }
    }

    func testWithdrawnOrReplacedProposalDuringProbeCannotSave() async throws {
        for withdraw in [true, false] {
            let connection = connection()
            let client = SyncFixtureClient(proposal: proposal())
            let stream = SyncFixtureStream()
            let sync = RemoteConnectionSyncController(client: client, streamer: stream, deviceID: "phone", now: { self.instant })
            let task = Task { await sync.poll(connection: connection, currentSourceID: { "mac-source" }) }
            try await waitUntil { stream.calls == 1 }
            var replacement = proposal()
            replacement.host = "100.64.0.9"
            await client.setProposal(withdraw ? nil : replacement)
            stream.deliver(Snapshot(sessions: [], serverTime: instant, sourceID: "mac-source"))
            await task.value
            XCTAssertEqual(connection.pairing, original)
            XCTAssertEqual(sync.state, .failed(.invalidated))
            let confirmations = await client.outcomes.filter { $0 == .confirmed }
            XCTAssertTrue(confirmations.isEmpty)
        }
    }

    func testFailedProposalOnlyRetriesOnUserRequest() async {
        let connection = connection()
        let client = SyncFixtureClient(proposal: proposal())
        let stream = SyncFixtureStream(error: URLError(.timedOut))
        let sync = RemoteConnectionSyncController(client: client, streamer: stream, deviceID: "phone", now: { self.instant })
        await sync.poll(connection: connection, currentSourceID: { "mac-source" })
        await sync.poll(connection: connection, currentSourceID: { "mac-source" })
        XCTAssertEqual(stream.calls, 1)
        XCTAssertEqual(connection.pairing, original)
        sync.retry()
        await sync.poll(connection: connection, currentSourceID: { "mac-source" })
        XCTAssertEqual(stream.calls, 2)
        XCTAssertEqual(connection.pairing, original)
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The remote probe did not start")
    }
}

private actor SyncFixtureClient: RemoteConnectionSyncClient {
    private var offered: RemoteConnectionProposal?
    private var failedConfirmations: Int
    private let rejectConfirmation: Bool
    private(set) var outcomes: [RemoteConnectionReceipt.Outcome] = []

    init(proposal: RemoteConnectionProposal, failedConfirmations: Int = 0, rejectConfirmation: Bool = false) {
        offered = proposal
        self.failedConfirmations = failedConfirmations
        self.rejectConfirmation = rejectConfirmation
    }

    func setProposal(_ proposal: RemoteConnectionProposal?) { offered = proposal }

    func proposal(_ pairing: PairingPayload, deviceID: String) async throws -> RemoteSyncPoll {
        offered.map(RemoteSyncPoll.proposal) ?? .empty
    }

    func receipt(_ receipt: RemoteConnectionReceipt, pairing: PairingPayload) async throws -> RemoteSyncReceiptResult {
        outcomes.append(receipt.outcome)
        if receipt.outcome == .confirmed, rejectConfirmation { return .invalidated }
        if receipt.outcome == .confirmed, failedConfirmations > 0 {
            failedConfirmations -= 1
            throw URLError(.timedOut)
        }
        return .accepted
    }
}

private final class SyncFixtureStream: SnapshotStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let snapshot: Snapshot?
    private let error: URLError?
    private var continuation: AsyncThrowingStream<Snapshot, Error>.Continuation?
    var calls: Int { lock.withLock { callCount } }

    init(snapshot: Snapshot? = nil, error: URLError? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                callCount += 1
                self.continuation = continuation
            }
            if let snapshot { continuation.yield(snapshot); continuation.finish() }
            if let error { continuation.finish(throwing: error) }
        }
    }

    func deliver(_ snapshot: Snapshot) {
        lock.withLock {
            continuation?.yield(snapshot)
            continuation?.finish()
        }
    }
}
