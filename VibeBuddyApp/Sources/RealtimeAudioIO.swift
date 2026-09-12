import Foundation
import AVFoundation
import os
import VibeBuddyKit

private let rtAudioLog = Logger(subsystem: "com.vibebuddy.app", category: "realtime-audio")

@MainActor
final class RealtimeAudioIO: VoiceCallAudio {
    nonisolated private let hardware: RealtimeAudioEngine
    private var wantsAudio = false
    private var callID = UUID()
    var onAudioFrame: ((Data, UUID) -> Void)?
    var onInputSuspensionChanged: ((Bool) async throws -> Void)?
    var onPlaybackDrained: (@Sendable () -> Void)?
    var onStateChanged: ((VoiceCallAudioState) -> Void)?
    var onRelease: (@Sendable (Bool, UUID, VoiceAudioReleaseGate) -> Void)? {
        didSet { hardware.onRelease = onRelease }
    }
    private let recovery: VoiceAudioRecovery
    private var sessionObservers: [NSObjectProtocol] = []

    init(inputSampleRate: Double = 16000) {
        let hardware = RealtimeAudioEngine(inputSampleRate: inputSampleRate)
        self.hardware = hardware
        recovery = VoiceAudioRecovery(rebuild: {
            let id = hardware.authorize()
            try await hardware.rebuild(id)
        }, release: { hardware.release() })
        hardware.onAudioFrame = { [weak self] data, generation in
            Task { @MainActor in
                guard let self, self.wantsAudio, !self.recovery.isRecovering,
                      self.hardware.acceptsCapture(generation) else { return }
                self.onAudioFrame?(data, generation)
            }
        }
        hardware.onPlaybackDrained = { [weak self] in
            Task { @MainActor in self?.onPlaybackDrained?() }
        }
        hardware.onConfigurationChange = { [weak self] generation in
            Task { @MainActor in
                guard let self, self.hardware.accepts(generation) else { return }
                self.hardware.revoke()
                self.recovery.request()
            }
        }
    }

    nonisolated func isCaptureCurrent(_ generation: UUID) -> Bool { hardware.acceptsCapture(generation) }

    var isPlaybackPending: Bool { hardware.isPlaybackPending }
    var isAudiblePlaybackPending: Bool { hardware.isAudiblePlaybackPending }

    func start() async throws {
        guard !wantsAudio else { return }
        wantsAudio = true
        callID = UUID()
        let call = callID
        recovery.canResume = true
        recovery.beforeRecovery = { [weak self] in try await self?.onInputSuspensionChanged?(true) }
        recovery.afterRebuild = { [weak self] in try await self?.onInputSuspensionChanged?(false) }
        recovery.onStateChanged = { [weak self] state in
            guard let self, self.wantsAudio else { return }
            if state == .running { self.hardware.enableCapture() }
            if case .failed = state { self.stop() }
            self.onStateChanged?(state)
        }
        recovery.activate()
        observeSession()
        let id = hardware.authorize()
        do {
            try await hardware.rebuild(id)
            guard wantsAudio, callID == call, hardware.accepts(id) else { throw CancellationError() }
            hardware.enableCapture()
        } catch {
            if callID == call { stop() }
            throw error
        }
    }

    func stop() {
        wantsAudio = false
        callID = UUID()
        recovery.stop()
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
    }

    func flushPlayback() -> [VoicePlaybackCheckpoint] { hardware.takePlaybackCheckpoints() }

    func enqueue(_ pcm: Data, item: VoiceAudioItem? = nil) {
        guard wantsAudio, !recovery.isRecovering, let id = hardware.currentGeneration else { return }
        hardware.enqueue(pcm, item: item, leaseID: id)
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let call = callID
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: nil) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, self.callID == call else { return }
                // Graph-format changes are handled by the engine observer. Do not
                // recycle the deadline for category changes caused by rebuilding.
                guard reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue ||
                      reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                      reason == AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue ||
                      reason == AVAudioSession.RouteChangeReason.override.rawValue ||
                      reason == AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue else { return }
                self.hardware.revoke()
                self.recovery.request()
            }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: nil) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, self.callID == call, self.wantsAudio else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.recovery.canResume = false
                    self.hardware.revoke()
                    self.recovery.request()
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    guard AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else {
                        self.stop()
                        self.onStateChanged?(.failed("Audio was interrupted. Tap the pet to start a new call."))
                        return
                    }
                    self.recovery.canResume = true
                    self.recovery.request()
                }
            }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.callID == call else { return }
                // Apple QA1749 requires an explicit user action after a media
                // services reset. End this call instead of restarting capture.
                self.hardware.markMediaServicesReset()
                self.stop()
                self.onStateChanged?(.failed("Audio services restarted. Tap the pet to start a new call."))
            }
        })
    }
}

/// AVFoundation graph access is confined to queue; bookkeeping and capture
/// leases use locks so hangup never waits for a synchronous hardware operation.
private final class RealtimeAudioEngine: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()

    private let captureFormat: AVAudioFormat
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 24000, channels: 1, interleaved: false)!

    /// `inputSampleRate` is the mic rate the chosen provider expects (Qwen/Gemini
    /// 16 kHz, OpenAI 24 kHz). Output is always 24 kHz PCM16.
    init(inputSampleRate: Double = 16000) {
        captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: inputSampleRate, channels: 1, interleaved: true)!
    }

    /// Called from the audio render thread with one mono PCM16 chunk —
    /// `@Sendable` so it stays non-isolated (never hops to the main actor).
    var onAudioFrame: (@Sendable (Data, UUID) -> Void)?

    /// Fired (on a background thread) when all queued playback buffers have drained
    /// — i.e. the queued audio has finished playing (also fires in network gaps).
    var onPlaybackDrained: (@Sendable () -> Void)?

    // AVAudioSession is process-wide. A replacement call must wait for the
    // previous instance's queued teardown before activating the shared session.
    private static let sessionQueue = DispatchQueue(label: "com.vibebuddy.voice.audio-engine")
    let queue = RealtimeAudioEngine.sessionQueue
    private let lease = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    private let captureLease = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    func enableCapture() { captureLease.withLock { $0 = currentGeneration } }
    func acceptsCapture(_ id: UUID) -> Bool { captureLease.withLock { $0 == id } && accepts(id) }
    var onConfigurationChange: (@Sendable (UUID) -> Void)?
    private var observer: NSObjectProtocol?
    private let mediaReset = OSAllocatedUnfairLock(initialState: false)
    func markMediaServicesReset() {
        revoke()
        mediaReset.withLock { $0 = true }
    }

    private let releaseGate = VoiceAudioReleaseGate()

    func authorize() -> UUID {
        captureLease.withLock { $0 = nil }
        releaseGate.advance()
        let id = UUID()
        lease.withLock { $0 = id }
        return id
    }
    var currentGeneration: UUID? { lease.withLock { $0 } }
    func revoke() { captureLease.withLock { $0 = nil }; lease.withLock { $0 = nil } }
    func accepts(_ id: UUID) -> Bool { lease.withLock { $0 == id } }

    func rebuild(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.accepts(id) else { continuation.resume(throwing: CancellationError()); return }
                guard self.stop() else {
                    continuation.resume(throwing: NSError(domain: "VoiceAudioRelease", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio resources could not be released."]))
                    return
                }
                self.engine = AVAudioEngine()
                self.player = AVAudioPlayerNode()
                do {
                    try self.start(id)
                    guard self.accepts(id) else { throw CancellationError() }
                    continuation.resume()
                } catch {
                    self.stop()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    var onRelease: (@Sendable (Bool, UUID, VoiceAudioReleaseGate) -> Void)?

    func release() {
        revoke()
        invalidatePlayback()
        let completion = onRelease
        let reportID = releaseGate.advance()
        queue.async {
            var released = self.stop()
            for _ in 0..<2 where !released {
                // The static hardware queue also serializes replacement-call
                // activation, so cleanup cannot deactivate a newer call.
                Thread.sleep(forTimeInterval: 0.15)
                released = self.stop()
            }
            if self.releaseGate.accepts(reportID) { completion?(released, reportID, self.releaseGate) }
        }
    }

    private let pendingLock = NSLock()
    private var pendingBuffers = 0
    private var audibleBuffers = 0
    private var pendingItems: [VoiceAudioItem: Int] = [:]
    private var playedItemFrames: [VoiceAudioItem: Int] = [:]
    private var latestItem: VoiceAudioItem?

    private var playbackGeneration: UInt64 = 0
    private var tapInstalled = false
    // Confined to sessionQueue, including ownership transfer. A new call
    // inherits any failed deactivation before its own activation can throw.
    nonisolated(unsafe) private static var sessionOwner: UUID?
    nonisolated(unsafe) private static var needsDeactivation = false
    private let sessionOwnerID = UUID()

    var isAudiblePlaybackPending: Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return audibleBuffers > 0
    }

    var isPlaybackPending: Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingBuffers > 0
    }

    func start(_ generation: UUID) throws {
        guard accepts(generation) else { throw CancellationError() }
        // Configure the audio session before touching the engine's input node so
        // the route (and its native format) reflect the record-capable category.
        Self.sessionOwner = sessionOwnerID
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        guard accepts(generation) else { throw CancellationError() }
        Self.needsDeactivation = true
        try session.setActive(true)

        guard accepts(generation) else { throw CancellationError() }
        let input = engine.inputNode
        // Materialize both I/O nodes before switching to voice processing.
        let output = engine.outputNode
        // Enable VPIO before reading formats or connecting the graph: changing
        // it replaces both I/O units and can change their processing formats.
        guard accepts(generation) else { throw CancellationError() }
        try input.setVoiceProcessingEnabled(true)
        guard accepts(generation) else { throw CancellationError() }
        let nativeFormat = input.outputFormat(forBus: 0)
        // Save this BEFORE connecting the player. AVAudioEngine's automatic
        // mixer connection can replace the output client rate with 44.1 kHz;
        // VPIO then fails with -10875 when its capture side is still 48 kHz.
        let outputFormat = output.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0,
              outputFormat.sampleRate > 0, outputFormat.channelCount > 0,
              let tapFormat = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: tapFormat, to: captureFormat) else {
            throw NSError(domain: "RealtimeAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable microphone format for voice processing."])
        }
        nonisolated(unsafe) let captureConverter = converter

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        // Let the mixer resample 24 kHz model audio into the VPIO output format.
        engine.connect(engine.mainMixerNode, to: output,
                       format: outputFormat)

        // AVFoundation invokes this off the main actor; do not inherit start() isolation.
        guard accepts(generation) else { throw CancellationError() }
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { @Sendable [weak self] buffer, _ in
            self?.captureAndForward(buffer, converter: captureConverter, generation: generation)
        }
        tapInstalled = true
        guard accepts(generation) else { throw CancellationError() }
        engine.prepare()
        guard accepts(generation) else { throw CancellationError() }
        try engine.start()
        guard accepts(generation), engine.isRunning, input.isVoiceProcessingEnabled else {
            throw CancellationError()
        }
        player.play()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.onConfigurationChange?(generation)
        }
        rtAudioLog.info("audio engine started (native \(nativeFormat.sampleRate, privacy: .public)Hz)")
    }

    @discardableResult
    func stop() -> Bool {
        var released = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let reset = mediaReset.withLock { value in
            defer { value = false }
            return value
        }
        if reset {
            // Orphaned audio objects must be discarded, not queried/restarted.
            tapInstalled = false
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            invalidatePlayback()
        } else {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            invalidatePlayback()
            player.stop()
            if engine.isRunning { engine.stop() }
            // Release voice processing before returning the audio session to others.
            if engine.inputNode.isVoiceProcessingEnabled {
                do {
                    try engine.inputNode.setVoiceProcessingEnabled(false)
                } catch {
                    released = false
                    rtAudioLog.error("disable voice processing failed code=\((error as NSError).code, privacy: .public)")
                }
            }
        }
        if Self.sessionOwner == sessionOwnerID, Self.needsDeactivation {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                Self.needsDeactivation = false
                Self.sessionOwner = nil
            } catch {
                released = false
                rtAudioLog.error("audio session release failed code=\((error as NSError).code, privacy: .public)")
            }
        }
        return released
    }

    /// Barge-in / reset: drop everything queued so the model stops talking.
    @discardableResult
    func takePlaybackCheckpoints() -> [VoicePlaybackCheckpoint] {
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
        queue.async {
            self.player.stop()
            if self.engine.isRunning { self.player.play() }
        }
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
    func enqueue(_ pcm16: Data, item: VoiceAudioItem? = nil, leaseID: UUID) {
        guard accepts(leaseID) else { return }
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
        // Reserve pending frames synchronously so flush/truncate sees queued
        // items too. Only graph scheduling crosses onto the audio queue.
        nonisolated(unsafe) let scheduledBuffer = buffer
        queue.async { [self] in
            guard accepts(leaseID) else { return }
            guard engine.isRunning else {
                onConfigurationChange?(leaseID)
                return
            }
            pendingLock.lock()
            let current = playbackGeneration == generation
            pendingLock.unlock()
            guard current else { return }
            player.scheduleBuffer(scheduledBuffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
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
    }

    private func captureAndForward(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, generation: UUID) {
        guard acceptsCapture(generation), let onAudioFrame else { return }
        guard buffer.format.sampleRate == converter.inputFormat.sampleRate,
              buffer.format.channelCount == converter.inputFormat.channelCount else {
            onConfigurationChange?(generation); return
        }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }

        // The converter input block is @Sendable; the buffer is consumed
        // synchronously inside convert(), so this capture is safe.
        nonisolated(unsafe) let inputBuffer = buffer
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
        if let error { rtAudioLog.error("convert: \(error.localizedDescription, privacy: .public)"); onConfigurationChange?(generation); return }
        guard out.frameLength > 0, let chan = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: chan, count: Int(out.frameLength) * 2)
        if acceptsCapture(generation) { onAudioFrame(data, generation) }
    }
}
