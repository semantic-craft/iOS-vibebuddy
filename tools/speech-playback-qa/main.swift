import AVFoundation
import Foundation
import VibeBuddyKit

struct SilentSynthesizer: SpeechSynthesizer {
    let data: Data
    func synthesize(_ text: String, apiKey: String) async throws -> Data { data }
}

@MainActor
final class ValidationGate {
    var entered = false
    var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: true); continuation = nil }
}

@main
struct SpeechPlaybackQA {
    @MainActor static func check(_ value: Bool, _ label: String) {
        guard value else { print("FAIL: \(label)"); exit(1) }
        print("PASS: \(label)")
    }

    @MainActor static func until(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            if ContinuousClock.now >= deadline { check(false, "Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func silence() -> Data {
        let samples = 16_000
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + samples * 2))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000))
        append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }

    @MainActor static func audioPlayer(_ reader: ReadAloud) -> AVAudioPlayer {
        let value = Mirror(reflecting: reader).children.first { $0.label == "player" }!.value
        guard let player = Mirror(reflecting: value).children.first?.value as? AVAudioPlayer else {
            fatalError("Reader did not create an AVAudioPlayer")
        }
        return player
    }

    @MainActor static func main() async throws {
        UserDefaults.standard.setVolatileDomain([VoiceSettings.readAloudProviderKey: "qwen"], forName: UserDefaults.argumentDomain)
        let data = silence()
        func reader() -> ReadAloud {
            ReadAloud(automaticKey: { _ in "synthetic-not-a-key" },
                      makeSynthesizer: { _ in SilentSynthesizer(data: data) })
        }

        let completion = reader()
        let completionGate = ValidationGate()
        completion.speak("Silent completion regression", validate: {
            if completion.status == "Playing speech", !completionGate.entered { return await completionGate.wait() }
            return true
        })
        try await until("completion validation") { completionGate.entered }
        let completedPlayer = audioPlayer(completion)
        check(completedPlayer.isPlaying, "Real AVAudioPlayer starts playing")
        try await until("native audio completion") { !completedPlayer.isPlaying }
        check(completedPlayer.currentTime == 0, "Native completion resets currentTime to zero")
        completionGate.release()
        try await until("completion validation returns") { completedPlayer.isPlaying || !completion.busy }
        check(!completedPlayer.isPlaying, "Validation returning after completion never restarts audio")
        try await until("reader completion") { !completion.busy }
        check(completion.status == "Playback complete", "Reader finishes after natural audio completion")

        let paused = reader()
        paused.speak("Silent pause regression")
        try await until("pause playback") { paused.status == "Playing speech" }
        let pausedPlayer = audioPlayer(paused)
        try await until("audio progress") { pausedPlayer.currentTime > 0.1 }
        paused.togglePause()
        let pausedTime = pausedPlayer.currentTime
        try await Task.sleep(for: .milliseconds(250))
        check(!pausedPlayer.isPlaying && abs(pausedPlayer.currentTime - pausedTime) < 0.02, "Explicit pause retains playback position")
        paused.togglePause()
        try await until("resumed progress") { pausedPlayer.isPlaying && pausedPlayer.currentTime > pausedTime + 0.05 }
        check(true, "Explicit resume continues from the paused position")
        try await until("resumed completion") { !paused.busy }

        let voice = reader()
        let voiceGate = ValidationGate()
        voice.speak("Silent voice regression", validate: {
            if voice.status == "Playing speech", !voiceGate.entered { return await voiceGate.wait() }
            return true
        })
        try await until("voice validation") { voiceGate.entered }
        let voicePlayer = audioPlayer(voice)
        voice.canSpeak = { false }
        voice.voiceStarted()
        voiceGate.release()
        try await Task.sleep(for: .milliseconds(150))
        check(!voicePlayer.isPlaying, "Voice starting during validation prevents playback resumption")
        voice.canSpeak = { true }
        try await until("voice gate reopening") { voicePlayer.isPlaying }
        check(true, "Automatic reading resumes when the voice gate reopens")
        try await until("voice completion") { !voice.busy }
        print("All speech playback checks passed using actual ReadAloud and silent AVAudioPlayer audio")
    }
}
