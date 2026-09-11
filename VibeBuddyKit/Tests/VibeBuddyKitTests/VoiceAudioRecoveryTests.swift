import Foundation
import Testing
@testable import VibeBuddyKit

@MainActor
struct VoiceAudioRecoveryTests {
    @Test func timeoutDoesNotWaitForBlockedHardwareOrResetOnRepeatedNotifications() async throws {
        var states: [VoiceCallAudioState] = []
        var pending: CheckedContinuation<Void, Never>?
        var releases = 0
        let recovery = VoiceAudioRecovery(budget: .milliseconds(100), interval: .milliseconds(1), rebuild: {
            await withCheckedContinuation { pending = $0 }
        }, release: { releases += 1 })
        recovery.onStateChanged = { states.append($0) }
        recovery.activate()
        recovery.request()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(10))
            recovery.request()
        }
        #expect(states.first == .recovering)
        #expect(states.count == 2)
        guard case .failed = states.last else { Issue.record("Expected deadline failure"); return }
        #expect(releases == 2)
        pending?.resume()
        try await Task.sleep(for: .milliseconds(10))
        #expect(!states.contains(.running))
    }

    @Test func hangupWhileHardwareStartsCannotResumeTheCall() async throws {
        var pending: CheckedContinuation<Void, Never>?
        var states: [VoiceCallAudioState] = []
        let recovery = VoiceAudioRecovery(budget: .seconds(1), interval: .milliseconds(1), rebuild: {
            await withCheckedContinuation { pending = $0 }
        }, release: {})
        recovery.onStateChanged = { states.append($0) }
        recovery.activate(); recovery.request()
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(1)) }
        #expect(pending != nil)
        recovery.stop()
        pending?.resume()
        try await Task.sleep(for: .milliseconds(10))
        #expect(states == [.recovering])
        #expect(!recovery.isRecovering)
    }

    @Test func interruptionWaitsForPermissionThenResumesWithoutASecondRecoveryWindow() async throws {
        var attempts = 0
        var states: [VoiceCallAudioState] = []
        let recovery = VoiceAudioRecovery(budget: .seconds(1), interval: .milliseconds(1), rebuild: {
            attempts += 1
        }, release: {})
        recovery.onStateChanged = { states.append($0) }
        recovery.activate(); recovery.canResume = false; recovery.request()
        try await Task.sleep(for: .milliseconds(20))
        #expect(attempts == 0 && states == [.recovering])
        recovery.canResume = true
        recovery.request()
        for _ in 0..<100 where !states.contains(.running) { try await Task.sleep(for: .milliseconds(1)) }
        #expect(attempts == 1 && states == [.recovering, .running])
        recovery.stop()
    }
}
