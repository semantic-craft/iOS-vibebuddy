import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
final class CloudflareConnectionTests: XCTestCase {
    private let direct = PairingPayload(host: "192.168.1.10", port: 9876, token: "fixture")
    private func store() -> (ConnectionStore, UserDefaults) {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let store = ConnectionStore(defaults: defaults, protectedDataAvailable: { true })
        store.save(direct)
        return (store, defaults)
    }
    func testOnlyMatchingSnapshotCommitsAndPersistsExplicitRoutes() async throws {
        let (store, defaults) = store()
        let attempt = CloudflareConnectionAttempt()
        var savedID: String?
        var deleted: [String] = []
        let stream = CloudflareProbe()
        attempt.start(origin: "https://mac.example.com", clientID: "id", secret: "secret", sourceID: "mac",
                      connection: store, streamer: stream,
                      saveCredential: { _, id in savedID = id }, deleteCredential: { deleted.append($0) })
        try await waitUntil { stream.started }
        XCTAssertEqual(store.pairing, direct)
        XCTAssertNil(savedID)
        stream.deliver(source: "mac")
        try await waitUntil { !attempt.isChecking }
        XCTAssertEqual(attempt.phase, .success)
        XCTAssertEqual(store.pairing?.cloudflareCredentialID, savedID)
        XCTAssertTrue(deleted.isEmpty)
        let restored = ConnectionStore(defaults: defaults, protectedDataAvailable: { true })
        XCTAssertEqual(restored.pairing, store.pairing)
        XCTAssertEqual(restored.directPairing, direct)
        XCTAssertEqual(restored.verifiedSourceID, "mac")
        restored.selectDirect()
        XCTAssertEqual(restored.pairing, direct)
        restored.selectCloudflare()
        XCTAssertEqual(restored.pairing, store.pairing)
        restored.selectDirect()
        let updated = PairingPayload(host: "100.64.0.5", port: 9876, token: direct.token)
        XCTAssertTrue(restored.saveVerifiedDirect(updated, sourceID: "mac"))
        XCTAssertEqual(restored.directPairing, updated)
        XCTAssertEqual(restored.cloudflarePairing, store.cloudflarePairing)
        let json = String(data: defaults.data(forKey: "vibebuddy.connectionRoutes")!, encoding: .utf8)!
        XCTAssertFalse(json.contains("secret"))
    }
    func testWrongMacAndCancellationNeverSaveCredentials() async throws {
        for cancel in [false, true] {
            let (store, _) = store()
            let attempt = CloudflareConnectionAttempt()
            var saved = false
            let stream = CloudflareProbe()
            attempt.start(origin: "https://mac.example.com", clientID: "id", secret: "secret", sourceID: "mac",
                          connection: store, streamer: stream,
                          saveCredential: { _, _ in saved = true }, deleteCredential: { _ in })
            try await waitUntil { stream.started }
            if cancel { attempt.cancel() }
            stream.deliver(source: "other")
            try await waitUntil { !attempt.isChecking }
            XCTAssertEqual(store.pairing, direct)
            XCTAssertNil(store.cloudflarePairing)
            XCTAssertFalse(saved)
            XCTAssertEqual(attempt.phase, cancel ? .idle : .failure(.wrongMac))
        }
    }
    func testKeychainFailureAndPairingChangeCannotCommitCandidate() async throws {
        let (store, _) = store()
        let attempt = CloudflareConnectionAttempt()
        let writeFailureStream = CloudflareProbe()
        attempt.start(origin: "https://mac.example.com", clientID: "id", secret: "secret", sourceID: "mac",
                      connection: store, streamer: writeFailureStream,
                      saveCredential: { _, _ in throw URLError(.cannotWriteToFile) }, deleteCredential: { _ in })
        try await waitUntil { writeFailureStream.started }
        writeFailureStream.deliver(source: "mac")
        try await waitUntil { !attempt.isChecking }
        XCTAssertEqual(attempt.phase, .failure(.credentials))
        XCTAssertEqual(store.pairing, direct)
        let stream = CloudflareProbe()
        var saved = false
        attempt.start(origin: "https://mac.example.com", clientID: "id", secret: "secret", sourceID: "mac",
                      connection: store, streamer: stream,
                      saveCredential: { _, _ in saved = true }, deleteCredential: { _ in })
        try await waitUntil { stream.started }
        let other = PairingPayload(host: "192.168.1.11", port: 9876, token: "other")
        store.save(other)
        stream.deliver(source: "mac")
        try await waitUntil { !attempt.isChecking }
        XCTAssertEqual(attempt.phase, .failure(.changed))
        XCTAssertEqual(store.pairing, other)
        XCTAssertFalse(saved)
    }
    func testFailedCredentialRemovalPreservesPairingAndAllowsRetry() throws {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        var locked = true
        let store = ConnectionStore(defaults: defaults, protectedDataAvailable: { true }, deleteCredential: { _ in
            if locked { throw CompanionTransportError.keychainWriteFailed }
        })
        store.save(direct)
        let cloudflare = try XCTUnwrap(direct.usingCloudflare(origin: "https://mac.example.com", credentialID: "fixture"))
        XCTAssertTrue(store.commitCloudflare(cloudflare, sourceID: "mac"))
        XCTAssertFalse(store.removeCloudflare())
        XCTAssertFalse(store.clear())
        XCTAssertFalse(store.save(direct))
        XCTAssertEqual(store.pairing, cloudflare)
        XCTAssertEqual(store.cloudflarePairing, cloudflare)
        locked = false
        XCTAssertTrue(store.removeCloudflare())
        XCTAssertEqual(store.pairing, direct)
        XCTAssertNil(store.cloudflarePairing)
    }

    func testQRCodeCannotImportLocalAccessCredentialReference() throws {
        let candidate = try XCTUnwrap(direct.usingCloudflare(origin: "https://mac.example.com", credentialID: "local-key"))
        let json = String(data: try JSONEncoder().encode(candidate), encoding: .utf8)!
        XCTAssertNil(QRScannerView.pairing(from: json))
    }
    private func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Cloudflare attempt did not finish")
    }
}

private final class CloudflareProbe: SnapshotStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Snapshot, Error>.Continuation?
    var started: Bool { lock.withLock { continuation != nil } }
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> {
        AsyncThrowingStream { continuation in lock.withLock { self.continuation = continuation } }
    }
    func deliver(source: String) {
        lock.withLock {
            continuation?.yield(Snapshot(sessions: [], serverTime: Date(), sourceID: source))
            continuation?.finish()
        }
    }
}
