import XCTest
import SwiftUI
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
final class ObservationDiagnosticsTests: XCTestCase {
    func testReasonPresentationAndLegacyFallback() {
        let cases: [(ObservationSource, ObservationHealth, String?, String, Color)] = [
            (.hook, .healthy, nil, "Healthy", .green),
            (.hook, .temporarilySilent, "awaitingActivity", "Configured, awaiting first activity", .gray),
            (.transcript, .temporarilySilent, nil, "No recent activity", .gray),
            (.statusline, .notInstalled, "optionalSourceNotConfigured", "Status line information not enabled", .gray),
            (.statusline, .notInstalled, nil, "Status line information not enabled", .gray),
            (.statusline, .notInstalled, "futureReason", "Status line information not enabled", .gray),
            (.rollout, .unknownVersion, "versionUnverified", "Version 0.153.4 not yet verified", .gray),
            (.rollout, .unknownVersion, "invalidSourceData", "Invalid source data", .orange),
            (.hook, .eventsMissing, "configurationIncomplete", "Configuration incomplete", .orange),
            (.rollout, .sourceUnreadable, nil, "Unreadable", .orange),
            (.hook, .eventsMissing, "futureReason", "Events missing", .orange)
        ]
        for (source, health, reason, title, color) in cases {
            let row = ObservationSourceDiagnostic(source: source, health: health,
                reasonCode: reason, sourceVersion: "0.153.4")
            XCTAssertEqual(row.diagnosticTitle, title)
            XCTAssertEqual(row.diagnosticColor, color)
            if health == .healthy || health == .temporarilySilent {
                XCTAssertNil(row.phoneNextStep)
            } else {
                XCTAssertNotNil(row.phoneNextStep)
            }
        }
    }

    func testUpstreamFramesWithOldDecoderStoreAndPhoneRendering() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "oh-upstream-frames", withExtension: "json"))
        let frames = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
        let pipe = AsyncStream<Snapshot>.makeStream()
        let store = DashboardStore(streamer: ControlledDiagnosticStreamer(stream: pipe.stream),
            notifier: SilentNotifier(), decisionClient: NullDecisionClient(), watchRelay: nil)
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
            pipe.continuation.yield(snapshot)
            for _ in 0..<100 {
                if store.observationDiagnostics == snapshot.observationDiagnostics ?? [],
                   store.allSessions.sorted(by: { $0.id < $1.id }) == snapshot.sessions.sorted(by: { $0.id < $1.id }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
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

    func testCompleteWireFramesKeepDiagnosticsAndSessionsUpdating() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        var snapshots: [Snapshot] = []
        for (index, status) in [SessionStatus.working, .needsResponse, .done].enumerated() {
            let row = ObservationSourceDiagnostic(source: .rollout, health: .unknownVersion,
                reasonCode: index == 0 ? nil : index == 1 ? "futureReason" : "versionUnverified", sourceVersion: "0.153.4")
            let session = AgentSession(id: "same-task", agent: .codex, project: "diagnostic-test",
                status: status, statusSince: now, updatedAt: now.addingTimeInterval(Double(index)))
            let snapshot = Snapshot(sessions: [session], serverTime: session.updatedAt, sourceID: "test-mac",
                observationDiagnostics: [.init(agent: .codex, sources: [row])])
            // Exercise the same complete envelope decoder as WebSocketSnapshotClient.
            let bytes = try JSONEncoder().encode(ServerEvent.snapshot(snapshot))
            guard case .snapshot(let decoded) = try JSONDecoder().decode(ServerEvent.self, from: bytes) else {
                return XCTFail("Snapshot frame lost")
            }
            XCTAssertEqual(decoded, snapshot)
            snapshots.append(decoded)
        }
        let pipe = AsyncStream<Snapshot>.makeStream()
        let store = DashboardStore(streamer: ControlledDiagnosticStreamer(stream: pipe.stream),
            notifier: SilentNotifier(), decisionClient: NullDecisionClient(), watchRelay: nil)
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        defer { store.stop(); pipe.continuation.finish() }
        for snapshot in snapshots {
            pipe.continuation.yield(snapshot)
            for _ in 0..<100 {
                if store.allSessions.first?.status == snapshot.sessions.first?.status { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(store.allSessions.map(\.status), snapshot.sessions.map(\.status))
            XCTAssertEqual(store.observationDiagnostics, snapshot.observationDiagnostics)
        }
    }
}

private struct ControlledDiagnosticStreamer: SnapshotStreaming {
    let stream: AsyncStream<Snapshot>
    func stream(_ pairing: PairingPayload) -> AsyncStream<Snapshot> { stream }
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
