import XCTest
import Combine
import SwiftUI
import UIKit
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
final class ObservationDiagnosticsTests: XCTestCase {
    func testUpstreamFramesWithOldDecoderStoreAndPhoneRendering() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "oh-upstream-frames", withExtension: "json"))
        let frames = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
        let pipe = AsyncThrowingStream<Snapshot, Error>.makeStream()
        let store = DashboardStore(streamer: ControlledDiagnosticStreamer(stream: pipe.stream),
            notifier: SilentNotifier(), decisionClient: NullDecisionClient(), watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        defer { store.stop(); pipe.continuation.finish() }
        var renderedReasons = Set<String>()
        for frame in frames {
            let data = try JSONSerialization.data(withJSONObject: frame)
            guard case .snapshot(let snapshot) = try JSONDecoder().decode(ServerEvent.self, from: data),
                  case .snapshot(let old) = try JSONDecoder().decode(OldPhoneEvent.self, from: data) else {
                return XCTFail("Complete frame did not decode")
            }
            XCTAssertEqual(old.sessions, snapshot.sessions)
            XCTAssertEqual(old.serverTime, snapshot.serverTime)
            XCTAssertEqual(old.sourceID, snapshot.sourceID)
            XCTAssertEqual(old.recentDirectories, snapshot.recentDirectories)
            XCTAssertEqual(old.dispatchAgents, snapshot.dispatchAgents)
            XCTAssertEqual(old.providerQuota, snapshot.providerQuota)
            XCTAssertEqual(old.observationDiagnostics?.flatMap { $0.sources.map(\.health) },
                           snapshot.observationDiagnostics?.flatMap { $0.sources.map(\.health) })
            // Wait for the actual published frame. The preceding frame may still
            // be completing an asynchronous ActivityKit update; this is not a latency test.
            let applied = expectation(description: "Next upstream frame installed")
            let subscription = store.$groups.dropFirst().sink { _ in applied.fulfill() }
            pipe.continuation.yield(snapshot)
            let result = await XCTWaiter.fulfillment(of: [applied], timeout: 5)
            XCTAssertEqual(result, .completed)
            subscription.cancel()
            XCTAssertEqual(store.allSessions.sorted(by: { $0.id < $1.id }), snapshot.sessions.sorted(by: { $0.id < $1.id }))
            XCTAssertEqual(store.observationDiagnostics, snapshot.observationDiagnostics ?? [])
            for row in store.observationDiagnostics.flatMap(\.sources) {
                let key = row.source.rawValue + "-" + (row.reasonCode ?? row.health.rawValue)
                guard renderedReasons.insert(key).inserted else { continue }
                let content = ObservationDiagnosticRow(source: row)
                    .frame(width: 310, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(16).background(Color.white).environment(\.colorScheme, .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let rendered = try XCTUnwrap(renderer.uiImage)
                XCTAssertGreaterThan(rendered.size.height, 40)
                let attachment = XCTAttachment(image: rendered)
                attachment.name = "OH3-phone-" + key
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        for key in ["hook-healthy", "hook-awaitingActivity", "statusline-optionalSourceNotConfigured",
                    "rollout-versionUnverified", "rollout-invalidSourceData", "rollout-sourceUnreadable"] {
            XCTAssertTrue(renderedReasons.contains(key), "Missing upstream case: \(key)")
        }
    }
}

private struct ControlledDiagnosticStreamer: SnapshotStreaming {
    let stream: AsyncThrowingStream<Snapshot, Error>
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> { stream }
}

private enum OldPhoneEvent: Codable {
    case snapshot(OldPhoneSnapshot)
    case sessionUpdated(AgentSession)
    case sessionRemoved(id: String)
}

// Stored properties copied from origin/main ece1e72, before OH-1. The other
// model types are unchanged by OH-1. This exercises the complete snapshot, not
// a permissive dictionary or the new diagnostic decoder disguised as an old one.
private struct OldPhoneSnapshot: Codable {
    var sourceID: String?
    var sessions: [AgentSession]
    var serverTime: Date
    var observationDiagnostics: [OldAgentDiagnostic]?
    var providerQuota: [ProviderQuota]?
    var recentDirectories: [String]?
    var dispatchAgents: [AgentKind]?
}
private struct OldAgentDiagnostic: Codable {
    let agent: AgentKind
    var sources: [OldSourceDiagnostic]
}
private struct OldSourceDiagnostic: Codable {
    let source: ObservationSource
    var health: ObservationHealth
    var lastObservedAt: Date?
    var configuredCoverage: [ObservationEventCoverage]
    var observedCoverage: [ObservationEventCoverage]
}
