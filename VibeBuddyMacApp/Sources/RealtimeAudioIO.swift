import Foundation
import AVFoundation
import os

private let rtAudioLog = Logger(subsystem: "com.vibebuddy.mac", category: "realtime-audio")

/// Full-duplex audio for the omni-realtime voice session, on one `AVAudioEngine`:
/// the mic tap is converted to **16 kHz mono PCM16** and handed to `onAudioFrame`;
/// incoming **24 kHz mono PCM16** is converted to float and streamed out a player
/// node. Deliberately NOT `@MainActor` — the tap runs on the audio render thread,
/// so the closure must stay non-isolated (a main-actor closure would trap).
///
/// Echo is handled by half-duplex gating (`micMuted`), not hardware AEC.
///
/// `@unchecked Sendable`: instances cross the main actor ↔ audio render thread.
/// All shared mutable state is either set once before `start()` (the callbacks)
/// or lock-guarded (`pendingBuffers`); `micMuted` is a benign single-word flag.
final class RealtimeAudioIO: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?

    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 24000, channels: 1, interleaved: false)!

    /// Called from the audio render thread with one 16 kHz mono PCM16 chunk —
    /// `@Sendable` so it stays non-isolated (never hops to the main actor).
    var onAudioFrame: (@Sendable (Data) -> Void)?

    /// Fired (on a background thread) when all queued playback buffers have drained
    /// — i.e. the model finished speaking out loud. Used to re-open the mic.
    var onPlaybackDrained: (@Sendable () -> Void)?

    private let pendingLock = NSLock()
    private var pendingBuffers = 0

    /// Half-duplex gate: while the model is speaking we stop forwarding mic audio
    /// so it doesn't hear its own voice (which would feed the server VAD and make
    /// it ramble to itself). Plain Bool, flipped from the main actor; a stray
    /// frame either side of the flip is harmless.
    nonisolated(unsafe) var micMuted = false

    func start() throws {
        let input = engine.inputNode
        let nativeFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: nativeFormat, to: captureFormat)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: nativeFormat) { [weak self] buffer, _ in
            self?.captureAndForward(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        rtAudioLog.info("audio engine started (native \(nativeFormat.sampleRate, privacy: .public)Hz)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        if engine.isRunning { engine.stop() }
    }

    /// Barge-in / reset: drop everything queued so the model stops talking.
    func flushPlayback() {
        player.stop()
        pendingLock.lock(); pendingBuffers = 0; pendingLock.unlock()
        player.play()
    }

    /// Queue one 24 kHz mono PCM16 chunk for playback.
    func enqueue(_ pcm16: Data) {
        let frames = AVAudioFrameCount(pcm16.count / 2)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frames),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        pcm16.withUnsafeBytes { raw in
            guard let samples = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<Int(frames) { out[i] = Float(samples[i]) / 32768.0 }
        }
        pendingLock.lock(); pendingBuffers += 1; pendingLock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.pendingLock.lock()
            self.pendingBuffers -= 1
            let drained = self.pendingBuffers == 0
            self.pendingLock.unlock()
            if drained { self.onPlaybackDrained?() }
        }
        if !player.isPlaying { player.play() }
    }

    private func captureAndForward(_ buffer: AVAudioPCMBuffer) {
        guard !micMuted, let converter, let onAudioFrame else { return }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }

        // The converter input block is @Sendable; the buffer is consumed
        // synchronously inside convert(), so this capture is safe.
        nonisolated(unsafe) let inputBuffer = buffer
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let error { rtAudioLog.error("convert: \(error.localizedDescription, privacy: .public)"); return }
        guard out.frameLength > 0, let chan = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: chan, count: Int(out.frameLength) * 2)
        onAudioFrame(data)
    }
}
