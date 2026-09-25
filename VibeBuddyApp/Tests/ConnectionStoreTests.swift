import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

/// A `UserDefaults` that can be made to answer the way the real one does while
/// the app's preferences are still protected: every read comes back empty,
/// while the bytes stay on disk. That is what a launch into the background
/// before the first unlock since boot sees.
private final class LockableDefaults: UserDefaults, @unchecked Sendable {
    var locked = false
    override func data(forKey defaultName: String) -> Data? {
        locked ? nil : super.data(forKey: defaultName)
    }
    /// What is actually on disk, whether or not the reads are locked.
    func storedData(forKey defaultName: String) -> Data? { super.data(forKey: defaultName) }
}

@MainActor
final class ConnectionStoreTests: XCTestCase {
    private let key = "vibebuddy.pairing"
    private let pairing = PairingPayload(host: "192.168.1.20", port: 9876, token: "saved", macName: "Studio")
    private func makeDefaults() -> LockableDefaults {
        let suite = UUID().uuidString
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return LockableDefaults(suiteName: suite)!
    }

    private func saved(in defaults: UserDefaults) throws -> PairingPayload {
        try JSONDecoder().decode(PairingPayload.self, from: XCTUnwrap(defaults.data(forKey: key)))
    }

    /// The regression this file exists for: a launch that could not read the
    /// defaults must not present an unpaired phone for the life of the process,
    /// and must not lose the Mac that is still on disk.
    func testLaunchThatCannotReadDefaultsRecoversOnReload() throws {
        let defaults = makeDefaults()
        ConnectionStore(defaults: defaults, protectedDataAvailable: { true }).save(pairing)

        defaults.locked = true
        let background = ConnectionStore(defaults: defaults, protectedDataAvailable: { false })
        XCTAssertNil(background.pairing)
        XCTAssertEqual(background.loadFailure, .protectedDataUnavailable)
        XCTAssertEqual(try JSONDecoder().decode(PairingPayload.self, from: XCTUnwrap(defaults.storedData(forKey: key))),
                       pairing, "A failed read must not delete the saved Mac")

        defaults.locked = false
        background.reloadSavedPairing()
        XCTAssertEqual(background.pairing, pairing)
        XCTAssertNil(background.loadFailure)
    }

    func testReloadKeepsThePairingItAlreadyHas() {
        let defaults = makeDefaults()
        let store = ConnectionStore(defaults: defaults, protectedDataAvailable: { true })
        store.save(pairing)
        defaults.locked = true
        store.reloadSavedPairing()
        XCTAssertEqual(store.pairing, pairing, "A later unreadable read must not undo a loaded pairing")
        XCTAssertNil(store.loadFailure)
    }

    /// Someone who reached the demo from the connect screen stays in it. The
    /// sample dashboard must not be swapped for a real Mac under them.
    func testReloadDoesNotPullSomeoneOutOfTheDemo() {
        let defaults = makeDefaults()
        ConnectionStore(defaults: defaults, protectedDataAvailable: { true }).save(pairing)
        defaults.locked = true
        let store = ConnectionStore(defaults: defaults, protectedDataAvailable: { false })
        store.enterDemo()
        defaults.locked = false
        store.reloadSavedPairing()
        XCTAssertTrue(store.demo)
        XCTAssertNil(store.pairing)
    }

    /// Bytes that will not decode are a failure to read, not an unpaired phone,
    /// and nothing may throw them away on their own.
    func testUndecodableSavedPairingIsReportedAndKept() {
        let defaults = makeDefaults()
        defaults.set(Data("not a pairing".utf8), forKey: key)
        let store = ConnectionStore(defaults: defaults, protectedDataAvailable: { true })
        XCTAssertNil(store.pairing)
        XCTAssertEqual(store.loadFailure, .unreadable)
        XCTAssertNotNil(defaults.data(forKey: key))
    }

    /// Leaving the demo is not a request to forget a Mac. Reachable because the
    /// demo is offered on the connect screen, which is where a phone lands when
    /// its saved pairing could not be read.
    func testExitingTheDemoKeepsAndRestoresTheSavedPairing() throws {
        let defaults = makeDefaults()
        ConnectionStore(defaults: defaults, protectedDataAvailable: { true }).save(pairing)

        defaults.locked = true
        let store = ConnectionStore(defaults: defaults, protectedDataAvailable: { false })
        store.enterDemo()
        defaults.locked = false

        store.exitDemo()
        XCTAssertFalse(store.demo)
        XCTAssertEqual(store.pairing, pairing)
        XCTAssertEqual(try saved(in: defaults), pairing)
    }

    /// The confirmed "Disconnect" still forgets the Mac completely.
    func testClearForgetsTheMacOnDiskAndInMemory() {
        let defaults = makeDefaults()
        let store = ConnectionStore(defaults: defaults, protectedDataAvailable: { true })
        store.save(pairing)
        store.clear()
        XCTAssertNil(store.pairing)
        XCTAssertNil(store.loadFailure)
        XCTAssertNil(defaults.data(forKey: key))
        store.reloadSavedPairing()
        XCTAssertNil(store.pairing, "Forgetting a Mac must survive the next read")
    }

    func testInvalidPairingIsNeverSaved() {
        let defaults = makeDefaults()
        let store = ConnectionStore(defaults: defaults, protectedDataAvailable: { true })
        store.save(PairingPayload(host: "", port: 0, token: ""))
        XCTAssertNil(store.pairing)
        XCTAssertNil(defaults.data(forKey: key))
    }
}

/// The camera's gate. Anything that fails here never reaches `ConnectionStore`,
/// which is what makes a mis-scan harmless to the Mac already saved.
final class PairingScanDecodingTests: XCTestCase {
    func testValidPairingCodeDecodes() throws {
        let code = #"{"host":"192.168.1.20","port":9876,"token":"abc","macName":"Studio"}"#
        let payload = try XCTUnwrap(QRScannerView.pairing(from: code))
        XCTAssertEqual(payload, PairingPayload(host: "192.168.1.20", port: 9876, token: "abc", macName: "Studio"))
    }

    func testCodeWithoutMacNameStillDecodes() throws {
        let payload = try XCTUnwrap(QRScannerView.pairing(from: #"{"host":"100.64.0.8","port":9876,"token":"abc"}"#))
        XCTAssertNil(payload.macName)
    }

    func testCodesTheAppMustRefuse() {
        for code in ["", "https://example.com", "{}",
                     #"{"host":"192.168.1.20","port":9876}"#,
                     #"{"host":"","port":9876,"token":"abc"}"#,
                     #"{"host":"192.168.1.20","port":0,"token":"abc"}"#,
                     #"{"host":"192.168.1.20","port":9876,"token":""}"#,
                     #"{"host":"192.168.1.20","port":9876,"token":"ab\nc"}"#] {
            XCTAssertNil(QRScannerView.pairing(from: code), "\(code) must not reach the store")
        }
    }
}
