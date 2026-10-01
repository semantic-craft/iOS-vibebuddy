import XCTest
import AVFoundation
import VibeBuddyKit
@testable import VibeBuddyApp

/// Opt-in acceptance of this batch only. Uses an isolated Mac and a temporary
/// provider key supplied out of band. Never emits request bodies or credentials.
@MainActor
final class IOSParityLiveTests: XCTestCase {
    func testRealMiniMaxStylesReachPhonePlayback() async throws {
        guard let key = ProcessInfo.processInfo.environment["VIBEBUDDY_QA_MINIMAX_KEY"], !key.isEmpty else {
            throw XCTSkip("Requires temporary MiniMax credential through the native secure prompt")
        }
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let requested = ProcessInfo.processInfo.environment["VIBEBUDDY_QA_MINIMAX_STYLE"].flatMap(VoiceStyle.init(rawValue:))
        for style in requested.map({ [$0] }) ?? VoiceStyle.allCases {
            UserDefaults.standard.setVolatileDomain([
                PhoneReadAloudSelection.defaultsKey: "minimax",
                PhoneReadAloudSelection.languageKey: "zh",
                VoiceSettings.readAloudStyleKey(.minimax): style.rawValue
            ], forName: UserDefaults.argumentDomain)
            let announcer = PhoneAnnouncer(providerKey: { _ in key })
            let began = Date()
            announcer.preview()
            var firstAudio: TimeInterval?
            var lastTick = began
            var maximumMainActorGap: TimeInterval = 0
            let deadline = Date().addingTimeInterval(60)
            while announcer.isPreviewing && Date() < deadline {
                let tick = Date()
                maximumMainActorGap = max(maximumMainActorGap, tick.timeIntervalSince(lastTick))
                lastTick = tick
                // Observe native AVAudioPlayer, not just an HTTP 200.
                if firstAudio == nil,
                   let optional = Mirror(reflecting: announcer).children.first(where: { $0.label == "player" })?.value,
                   let player = Mirror(reflecting: optional).children.first?.value as? AVAudioPlayer,
                   player.isPlaying { firstAudio = Date().timeIntervalSince(began) }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(firstAudio, "Real audio must reach the iOS player for \(style.rawValue)")
            XCTAssertFalse(announcer.canUseSystemSpeech, "Real provider playback must not fall back")
            XCTAssertEqual(announcer.spokenCount, 1)
            print("IOS_PARITY_TTS style=\(style.rawValue) first_audio_seconds=\(firstAudio ?? -1) total_seconds=\(Date().timeIntervalSince(began)) main_actor_max_gap_seconds=\(maximumMainActorGap)")
            announcer.stop()
        }
    }

    func testRealTaskReadsAndHistoryKeepSourceIdentity() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VIBEBUDDY_QA_HOST"], let port = env["VIBEBUDDY_QA_PORT"].flatMap(Int.init), port != 9876,
              let key = env["VIBEBUDDY_QA_TOKEN"], let id = env["VIBEBUDDY_QA_SESSION"] else { throw XCTSkip("Requires isolated Mac with real Codex data") }
        let pairing = PairingPayload(host: host, port: port, token: key)
        let snapshot = try await RemoteConnectionCheck.verify(pairing)
        let source = try XCTUnwrap(snapshot.sourceID)
        let client = HTTPDecisionClient()
        let capability = try await client.taskReadCapabilities(pairing)
        XCTAssertEqual(capability.sourceID, source)
        XCTAssertEqual(Set(capability.supported), Set(TaskReadKind.allCases))
        for kind in TaskReadKind.allCases {
            let started = Date()
            let response = try await client.taskRead(pairing, sourceID: source, sessionID: id, kind: kind, cursor: nil)
            XCTAssertEqual(response.sourceID, source); XCTAssertEqual(response.sessionID, id); XCTAssertEqual(response.kind, kind)
            print("IOS_PARITY_READ kind=\(kind.rawValue) seconds=\(Date().timeIntervalSince(started)) failure=\(response.failure ?? "none")")
        }
        let started = Date()
        let history = try await client.history(pairing, sourceID: source, key: "codex:" + id, cursor: nil)
        XCTAssertFalse(history.messages.isEmpty)
        print("IOS_PARITY_LOCAL_HISTORY seconds=\(Date().timeIntervalSince(started)) messages=\(history.messages.count)")
        let after = try await RemoteConnectionCheck.verify(pairing)
        XCTAssertEqual(snapshot.sessions.first(where: { $0.id == id })?.hasUnreadCompletion,
                       after.sessions.first(where: { $0.id == id })?.hasUnreadCompletion)
    }
}
