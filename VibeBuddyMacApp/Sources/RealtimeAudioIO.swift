import Foundation
import AVFoundation
import CoreAudio
import os
import VibeBuddyKit

private let rtAudioLog = Logger(subsystem: "com.vibebuddy.mac", category: "realtime-audio")

/// Full-duplex audio with system voice processing (AEC). Hardware runs at its
/// negotiated format; only the provider boundary is resampled to 16/24 kHz.
/// Control methods run on the main actor; the tap and completion callbacks run
/// on audio threads. Playback bookkeeping is lock guarded.
final class RealtimeAudioIO: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    @MainActor var onCleanupError: ((String) -> Void)?
    @MainActor var onAvailabilityChanged: ((VoiceAudioAvailability) -> Void)?
    @MainActor var onInputSuspensionChanged: ((Bool) async throws -> Void)?
    @MainActor private var active = false
    @MainActor private var lifecycle: UInt64 = 0
    @MainActor private var graphGeneration: UInt64 = 0
    @MainActor private var recoveryTask: Task<Void, Never>?
    @MainActor private var recoveryDirty = false
    @MainActor private var configurationObserver: NSObjectProtocol?
    @MainActor private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var captureGeneration: UInt64 = 0
    private var captureEnabled = false

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
    var onAudioFrame: (@Sendable (Data, UInt64) -> Void)?

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

    func isCaptureCurrent(_ generation: UInt64) -> Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return captureEnabled && captureGeneration == generation
    }

    private func closeCaptureGate() {
        pendingLock.lock(); defer { pendingLock.unlock() }
        captureEnabled = false
        captureGeneration &+= 1
    }

    private func openCaptureGate() {
        pendingLock.lock(); defer { pendingLock.unlock() }
        captureEnabled = true
    }

    private func currentCaptureGeneration() -> UInt64 {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return captureGeneration
    }

    @MainActor
    func start() throws {
        guard !active else { return }
        lifecycle &+= 1
        active = true
        closeCaptureGate()
        do {
            try tearDownGraph()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            try buildGraph()
            try observeDevices()
            openCaptureGate()
            onAvailabilityChanged?(.available)
        } catch {
            stop()
            throw error
        }
    }

    @MainActor
    private func buildGraph() throws {
        let input = engine.inputNode
        let output = engine.outputNode
        try input.setVoiceProcessingEnabled(true)
        let nativeFormat = input.outputFormat(forBus: 0)
        // Save before connecting the player: the automatic mixer connection can
        // otherwise change the VPIO output client rate independently of input.
        let outputFormat = output.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0,
              outputFormat.sampleRate > 0, outputFormat.channelCount > 0,
              let tapFormat = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: tapFormat, to: captureFormat) else {
            throw NSError(domain: "RealtimeAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable input/output audio format. Please reconnect your audio device."])
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.connect(engine.mainMixerNode, to: output, format: outputFormat)
        let generation = currentCaptureGeneration()
        let frameHandler = onAudioFrame
        // A tap owns its converter; replacing the graph never mutates the
        // converter an old render callback may still be using.
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { @Sendable [weak self] buffer, _ in
            self?.captureAndForward(buffer, converter: converter, generation: generation, frameHandler: frameHandler)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        player.play()
        graphGeneration &+= 1
        let graph = graphGeneration
        let call = lifecycle
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycle == call, self.graphGeneration == graph else { return }
                self.requestRecovery()
            }
        }
        rtAudioLog.info("audio engine started (native \(nativeFormat.sampleRate, privacy: .public)Hz)")
    }

    @MainActor
    private func observeDevices() throws {
        let call = lifecycle
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.lifecycle == call else { return }
                    self.requestRecovery()
                }
            }
            let result = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
            guard result == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(result),
                    userInfo: [NSLocalizedDescriptionKey: "Unable to monitor audio device changes."])
            }
            deviceListeners.append((address, block))
        }
    }

    @MainActor
    private func requestRecovery() {
        guard active else { return }
        closeCaptureGate()
        onAvailabilityChanged?(.recovering)
        guard active else { return }
        invalidatePlayback()
        player.stop()
        recoveryDirty = true
        guard recoveryTask == nil else { return }
        let call = lifecycle
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            do {
                try self.tearDownGraph()
                guard ContinuousClock.now.advanced(by: .seconds(2)) < deadline else {
                    throw NSError(domain: "RealtimeAudio", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Audio recovery budget exhausted. Start a new call."])
                }
                try await self.onInputSuspensionChanged?(true)
                guard self.isActive(call) else { return }
                var lastError: Error?
                for delay in [100, 250, 500] {
                    guard ContinuousClock.now < deadline else { break }
                    try await Task.sleep(for: .milliseconds(delay))
                    guard self.isActive(call) else { return }
                    self.recoveryDirty = false
                    do {
                        try self.tearDownGraph()
                        self.engine = AVAudioEngine()
                        self.player = AVAudioPlayerNode()
                        try self.buildGraph()
                    } catch {
                        lastError = error
                        continue
                    }
                    // Yield so queued device notifications invalidate this attempt.
                    await Task.yield()
                    guard self.isActive(call) else { return }
                    if self.recoveryDirty || !self.engine.isRunning { continue }
                    guard ContinuousClock.now.advanced(by: .seconds(2)) < deadline else { break }
                    try await self.onInputSuspensionChanged?(false)
                    guard self.isActive(call) else { return }
                    if self.recoveryDirty || !self.engine.isRunning {
                        guard ContinuousClock.now.advanced(by: .seconds(2)) < deadline else { break }
                        try await self.onInputSuspensionChanged?(true)
                        continue
                    }
                    guard ContinuousClock.now < deadline else { break }
                    self.openCaptureGate()
                    self.recoveryTask = nil
                    self.onAvailabilityChanged?(.available)
                    return
                }
                throw lastError ?? NSError(domain: "RealtimeAudio", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Audio recovery did not finish. Please start a new call."])
            } catch {
                guard self.isActive(call) else { return }
                let message = "Audio recovery failed: " + error.localizedDescription
                self.stop()
                self.onAvailabilityChanged?(.failed(message))
            }
        }
    }

    @MainActor
    private func isActive(_ call: UInt64) -> Bool {
        active && lifecycle == call && !Task.isCancelled
    }

    @MainActor
    private func tearDownGraph() throws {
        graphGeneration &+= 1
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        invalidatePlayback()
        player.stop()
        engine.stop()
        if engine.inputNode.isVoiceProcessingEnabled {
            try engine.inputNode.setVoiceProcessingEnabled(false)
        }
    }

    @MainActor
    func stop() {
        active = false
        lifecycle &+= 1
        closeCaptureGate()
        recoveryTask?.cancel()
        recoveryTask = nil
        for (var address, block) in deviceListeners {
            let result = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
            if result != noErr { rtAudioLog.error("remove device listener: \(result, privacy: .public)") }
        }
        deviceListeners.removeAll()
        do { try tearDownGraph() }
        catch {
            rtAudioLog.error("disable voice processing: \(error.localizedDescription, privacy: .public)")
            onCleanupError?("Audio stopped, but voice processing could not be released: " + error.localizedDescription)
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
        guard active, recoveryTask == nil else { return }
        guard engine.isRunning else { requestRecovery(); return }
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

    private func captureAndForward(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                                   generation: UInt64, frameHandler: (@Sendable (Data, UInt64) -> Void)?) {
        guard isCaptureCurrent(generation), let frameHandler else { return }
        guard buffer.format.sampleRate == converter.inputFormat.sampleRate,
              buffer.format.channelCount == converter.inputFormat.channelCount else {
            Task { @MainActor [weak self] in
                guard let self, self.isCaptureCurrent(generation) else { return }
                self.requestRecovery()
            }
            return
        }
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
        if let error {
            rtAudioLog.error("convert: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor [weak self] in
                guard let self, self.isCaptureCurrent(generation) else { return }
                self.requestRecovery()
            }
            return
        }
        guard out.frameLength > 0, let chan = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: chan, count: Int(out.frameLength) * 2)
        guard isCaptureCurrent(generation) else { return }
        frameHandler(data, generation)
    }
}

extension RealtimeAudioIO: VoiceCallAudio {}
