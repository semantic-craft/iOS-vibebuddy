import Foundation
import AVFoundation
import os
import VibeBuddyKit

private let rtAudioLog = Logger(subsystem: "com.vibebuddy.mac", category: "realtime-audio")

/// Full-duplex audio with system voice processing (AEC). Hardware runs at its
/// negotiated format; only the provider boundary is resampled to 16/24 kHz.
/// Control methods run on the main actor; the tap and completion callbacks run
/// on audio threads. Playback bookkeeping is lock guarded.
final class RealtimeAudioIO: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?

    private let captureFormat: AVAudioFormat
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 24000, channels: 1, interleaved: false)!

    /// `inputSampleRate` is the mic rate the chosen provider expects (Qwen/Gemini
    /// 16 kHz, OpenAI 24 kHz). Output is always 24 kHz PCM16.
    init(inputSampleRate: Double = 16000) {
        captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: inputSampleRate, channels: 1, interleaved: true)!
    }

    /// Called from the audio render thread with one 16 kHz mono PCM16 chunk —
    /// `@Sendable` so it stays non-isolated (never hops to the main actor).
    var onAudioFrame: (@Sendable (Data) -> Void)?

    /// Fired (on a background thread) when all queued playback buffers have drained
    /// — i.e. the queued audio has finished playing (also fires in network gaps).
    var onPlaybackDrained: (@Sendable () -> Void)?

    private let pendingLock = NSLock()
    private var pendingBuffers = 0
    private var audibleBuffers = 0
    private var pendingItems: [VoiceAudioItem: Int] = [:]
    private var playedItemFrames: [VoiceAudioItem: Int] = [:]
    private var latestItem: VoiceAudioItem?

    private var playbackGeneration: UInt64 = 0
    private var tapInstalled = false

    var isAudiblePlaybackPending: Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return audibleBuffers > 0
    }

    var isPlaybackPending: Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingBuffers > 0
    }

    @MainActor
    func start() throws {
        let input = engine.inputNode
        // Materialize both I/O nodes before switching to voice processing.
        let output = engine.outputNode
        // Enable VPIO before reading formats or connecting the graph: changing
        // it replaces both I/O units and can change their processing formats.
        try input.setVoiceProcessingEnabled(true)
        let nativeFormat = input.outputFormat(forBus: 0)
        // Save this BEFORE connecting the player. AVAudioEngine's automatic
        // mixer connection can replace the output client rate with 44.1 kHz;
        // VPIO then fails with -10875 when its capture side is still 48 kHz.
        let outputFormat = output.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0,
              let tapFormat = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: tapFormat, to: captureFormat) else {
            throw NSError(domain: "RealtimeAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable microphone format for voice processing."])
        }
        self.converter = converter

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        // Let the mixer resample 24 kHz model audio into the VPIO output format.
        engine.connect(engine.mainMixerNode, to: output,
                       format: outputFormat)

        // AVFoundation invokes this off the main actor; do not inherit start() isolation.
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { @Sendable [weak self] buffer, _ in
            self?.captureAndForward(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        player.play()
        rtAudioLog.info("audio engine started (native \(nativeFormat.sampleRate, privacy: .public)Hz)")
    }

    @MainActor
    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        invalidatePlayback()
        player.stop()
        if engine.isRunning { engine.stop() }
        // Stopping rendering alone can leave VPIO ducking other applications.
        // Disable both I/O units while stopped, even if this object is retained.
        if engine.inputNode.isVoiceProcessingEnabled {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(false)
            } catch {
                rtAudioLog.error("disable voice processing: \(error.localizedDescription, privacy: .public)")
            }
        }
        rtAudioLog.info("audio stopped voiceProcessing=\(self.engine.inputNode.isVoiceProcessingEnabled, privacy: .public)")
    }

    /// Barge-in / reset: drop everything queued so the model stops talking.
    @MainActor
    @discardableResult
    func flushPlayback() -> [VoicePlaybackCheckpoint] {
        pendingLock.lock()
        var interruptedItems = Set(pendingItems.keys)
        if let latestItem { interruptedItems.insert(latestItem) }
        let checkpoints = interruptedItems.map { item in
            VoicePlaybackCheckpoint(item: item,
                audioEndMilliseconds: (playedItemFrames[item, default: 0] * 1000) / 24000)
        }
        pendingLock.unlock()
        // stop() can deliver callbacks for discarded buffers. Invalidate those
        // before stopping, so they cannot drain a subsequent response's queue.
        invalidatePlayback()
        player.stop()
        if engine.isRunning { player.play() }
        return checkpoints
    }

    private func invalidatePlayback() {
        pendingLock.lock(); defer { pendingLock.unlock() }
        playbackGeneration &+= 1
        pendingBuffers = 0
        audibleBuffers = 0
        pendingItems.removeAll()
        playedItemFrames.removeAll()
        latestItem = nil
    }

    /// Queue one 24 kHz mono PCM16 chunk for playback.
    @MainActor
    func enqueue(_ pcm16: Data, item: VoiceAudioItem? = nil) {
        guard engine.isRunning else { return }
        let frames = AVAudioFrameCount(pcm16.count / 2)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frames),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        pcm16.withUnsafeBytes { raw in
            guard let samples = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<Int(frames) { out[i] = Float(samples[i]) / 32768.0 }
        }
        let audible = VoicePCM.hasAudibleSignal(pcm16)
        pendingLock.lock()
        pendingBuffers += 1
        if audible { audibleBuffers += 1 }
        if let item {
            pendingItems[item, default: 0] += 1
            latestItem = item
        }
        let generation = playbackGeneration
        pendingLock.unlock()
        // Playback callbacks also run off the main actor.
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            guard let self else { return }
            self.pendingLock.lock()
            guard self.playbackGeneration == generation else {
                self.pendingLock.unlock()
                return
            }
            self.pendingBuffers -= 1
            if audible { self.audibleBuffers -= 1 }
            if let item {
                self.playedItemFrames[item, default: 0] += Int(frames)
                self.pendingItems[item, default: 0] -= 1
                if self.pendingItems[item] == 0 { self.pendingItems[item] = nil }
            }
            let drained = self.pendingBuffers == 0 || (audible && self.audibleBuffers == 0)
            self.pendingLock.unlock()
            if drained { self.onPlaybackDrained?() }
        }
        if !player.isPlaying { player.play() }
    }

    private func captureAndForward(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let onAudioFrame else { return }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }

        // The converter input block is @Sendable; the buffer is consumed
        // synchronously inside convert(), so this capture is safe.
        nonisolated(unsafe) let inputBuffer = buffer
        // The input block is `@Sendable`, so the "already handed this buffer
        // over" flag must not be a captured `var`: nothing in the AVAudioConverter
        // contract promises the block only ever runs on this thread, and a torn
        // read there would feed the same buffer twice (or none). The lock is
        // itself Sendable, so the capture is immutable and the one-shot
        // hand-off is a single atomic test-and-set.
        let fed = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            let alreadyFed = fed.withLock { flag in
                defer { flag = true }
                return flag
            }
            if alreadyFed { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return inputBuffer
        }
        if let error { rtAudioLog.error("convert: \(error.localizedDescription, privacy: .public)"); return }
        guard out.frameLength > 0, let chan = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: chan, count: Int(out.frameLength) * 2)
        onAudioFrame(data)
    }
}

extension RealtimeAudioIO: VoiceCallAudio {}
