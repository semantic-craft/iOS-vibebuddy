import Combine
import SwiftUI
import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
final class GrokMonitoringPhoneTests: XCTestCase {
    func testDiscoverySnapshotsNeverBecomeTasksAndResetWithTheSource() async throws {
        for reset in 0..<3 {
            let pipe = AsyncThrowingStream<Snapshot, Error>.makeStream()
            let store = DashboardStore(streamer: GrokPhoneStream(value: pipe.stream),
                notifier: SilentNotifier(), decisionClient: NullDecisionClient(),
                watchRelay: nil, reportDevice: { _ in })
            let pairing = PairingPayload(host: "127.0.0.1", port: 9, token: "test")
            store.start(pairing)
            defer { store.stop(); pipe.continuation.finish() }
            var snapshot = Snapshot(sessions: [], serverTime: Date(), sourceID: "mac")
            snapshot.grokMonitoring = .init(enabled: true, configured: true, available: true,
                connectedSessionCount: 0, discoveredSessions: [.init(id: "grok-live", cwd: "/tmp/project")])

            func send(_ snapshot: Snapshot) async {
                let applied = expectation(description: "Snapshot installed")
                let subscription = store.$groups.dropFirst().sink { _ in applied.fulfill() }
                pipe.continuation.yield(snapshot)
                await fulfillment(of: [applied], timeout: 5)
                subscription.cancel()
            }

            await send(snapshot)
            XCTAssertEqual(store.grokMonitoring?.discoveredSessions.first?.project, "project")
            XCTAssertTrue(store.allSessions.isEmpty)
            var legacy = snapshot
            legacy.grokMonitoring = nil
            legacy.serverTime.addTimeInterval(1)
            await send(legacy)
            XCTAssertNil(store.grokMonitoring, "A legacy Mac must not retain an earlier status")
            snapshot.serverTime.addTimeInterval(2)
            await send(snapshot)
            snapshot.sourceID = "new-mac"
            await send(snapshot)
            XCTAssertNotNil(store.grokMonitoring, "The new Mac's first frame survives source cleanup")
            store.stop()
            XCTAssertNotNil(store.grokMonitoring, "Disconnect preserves the labeled last snapshot")
            switch reset {
            case 0: store.start(PairingPayload(host: "another-mac", port: 9, token: "test"))
            case 1: store.forgetPairing()
            default: store.startDemo()
            }
            XCTAssertNil(store.grokMonitoring)
        }
    }

    func testConnectionCardRendersAtAccessibilitySize() throws {
        let status = GrokMonitoringStatus(enabled: true, configured: false, available: true,
            error: "Could not save Grok configuration", connectedSessionCount: 0,
            discoveredSessions: [.init(id: "discovered", cwd: "/tmp/example-project")])
        let renderer = ImageRenderer(content: PhoneGrokMonitoring(status: status)
            .environment(\.dynamicTypeSize, .accessibility3)
            .frame(width: 320).fixedSize(horizontal: false, vertical: true)
            .padding().background(CompanionPalette.bg))
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 200)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Grok connection error and discovery — accessibility size"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct GrokPhoneStream: SnapshotStreaming {
    let value: AsyncThrowingStream<Snapshot, Error>
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> { value }
}
