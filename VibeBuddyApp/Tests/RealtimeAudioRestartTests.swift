import AVFoundation
import XCTest
import os
import VibeBuddyKit
@testable import VibeBuddyApp

/// Opt-in physical audio acceptance; requires existing microphone permission.
@MainActor
final class RealtimeAudioRestartTests: XCTestCase {
    func testReplacementCapturesAfterPreviousCallReleases() async throws {
        guard ProcessInfo.processInfo.environment["VIBEBUDDY_AUDIO_RESTART_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Run explicitly on a real iPhone with microphone access.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical audio hardware.")
        #else
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("Microphone permission must already be granted.")
        }
        for round in 0..<5 {
            let old = RealtimeAudioIO()
            let replacement = RealtimeAudioIO()
            defer { old.stop(); replacement.stop() }
            let released = OSAllocatedUnfairLock<(Bool, UUID, VoiceAudioReleaseGate)?>(initialState: nil)
            old.onRelease = { success, reportID, gate in
                released.withLock { $0 = (success, reportID, gate) }
            }
            try await old.start()
            old.stop()
            // No wait between old teardown and replacement activation.
            try await replacement.start()
            let deadline = Date().addingTimeInterval(3)
            while released.withLock({ $0 == nil }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let report = try XCTUnwrap(released.withLock { $0 })
            XCTAssertTrue(report.0 && report.2.accepts(report.1), "Old release failed or became stale in round \(round)")
            var freshFrames = 0
            replacement.onAudioFrame = { _, _ in freshFrames += 1 }
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertGreaterThan(freshFrames, 3, "Replacement lost capture after old release in round \(round)")
            replacement.stop()
        }
        #endif
    }
}
