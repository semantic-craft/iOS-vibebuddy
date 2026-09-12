import Foundation
import AVFoundation
import os
import VibeBuddyKit

private let rtAudioLog = Logger(subsystem: "com.vibebuddy.app", category: "realtime-audio")

/// Full-duplex audio with system voice processing (AEC). Hardware runs at its
/// negotiated format; only the provider boundary is resampled to 16/24 kHz.
/// Control methods run on the main actor; the tap and completion callbacks run
/// on audio threads. Playback bookkeeping is lock guarded.
final class RealtimeAudioIO: @unchecked Sendable {
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

    @MainActor var onAvailabilityChanged: ((VoiceAudioAvailability) -> Void)?
    @MainActor var onInputSuspensionChanged: ((Bool) async throws -> Void)?
    @MainActor var onCleanupError: ((String) -> Void)?
    @MainActor private var callID: UUID?
    @MainActor private var interrupted = false
    @MainActor private var recoveryTask: Task<Void, Never>?
    @MainActor private var cleanupTask: Task<Void, Never>?
    @MainActor private var observers: [NSObjectProtocol] = []
    @MainActor private var engineObserver: NSObjectProtocol?
    @MainActor private var graphID = UUID()
    @MainActor private var routeRevision = 0
    private let captureLock = NSLock()
    private var captureGeneration: UInt64 = 0
    private var captureEnabled = false

    func isCaptureCurrent(_ generation: UInt64) -> Bool {
        captureLock.lock(); defer { captureLock.unlock() }
        return captureEnabled && captureGeneration == generation
    }

    @discardableResult
    private func setCaptureEnabled(_ enabled: Bool) -> UInt64 {
        captureLock.lock(); defer { captureLock.unlock() }
        captureGeneration &+= 1
        captureEnabled = enabled
        return captureGeneration
    }

    @MainActor
    func start() throws {
        guard callID == nil else { return }
        let id = VoiceAudioSessionOwnership.shared.claim()
        callID = id
        interrupted = false
        installSessionObservers(id: id)
        do {
            try startGraph()
            onAvailabilityChanged?(.available)
        } catch {
            stop()
            throw error
        }
    }

    @MainActor
    private func startGraph() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        if let callID { VoiceAudioSessionOwnership.shared.markActivationAttempt(owner: callID) }
        try session.setActive(true)
        let input = engine.inputNode
        let output = engine.outputNode
        try input.setVoiceProcessingEnabled(true)
        let nativeFormat = input.outputFormat(forBus: 0)
        let outputFormat = output.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0,
              outputFormat.sampleRate > 0, outputFormat.channelCount > 0,
              let tapFormat = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: tapFormat, to: captureFormat) else {
            throw NSError(domain: "RealtimeAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No usable input/output audio format."])
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.connect(engine.mainMixerNode, to: output, format: outputFormat)
        // Capture a converter per graph, never a mutable converter shared with
        // a rebuilding graph. The gate opens only after provider unmute ACK.
        let generation = setCaptureEnabled(false)
        let callback = onAudioFrame
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { @Sendable [weak self] buffer, _ in
            guard let self, self.isCaptureCurrent(generation) else { return }
            self.captureAndForward(buffer, converter: converter, generation: generation, callback: callback)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        player.play()
        if recoveryTask == nil { openCaptureGate() }
        let currentGraph = UUID(); graphID = currentGraph
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.graphID == currentGraph else { return }
                self.requestRecovery()
            }
        }
    }

    private func openCaptureGate() {
        captureLock.lock(); captureEnabled = true; captureLock.unlock()
    }

    @MainActor
    private func installSessionObservers(id: UUID) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: nil) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, self.callID == id,
                      reason != AVAudioSession.RouteChangeReason.categoryChange.rawValue else { return }
                self.requestRecovery()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: nil) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, self.callID == id else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.interrupted = true
                    self.recoveryTask?.cancel(); self.recoveryTask = nil
                    self.setCaptureEnabled(false)
                    self.onAvailabilityChanged?(.interrupted)
                    guard self.callID == id else { return }
                    do { try self.tearDownGraph() }
                    catch { self.onAvailabilityChanged?(.failed(error.localizedDescription)); return }
                    self.recoveryTask = Task { [weak self] in
                        guard let self else { return }
                        do { try await self.onInputSuspensionChanged?(true) }
                        catch {
                            guard self.callID == id, !Task.isCancelled else { return }
                            self.onAvailabilityChanged?(.failed(error.localizedDescription))
                        }
                    }
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    guard self.interrupted else { return }
                    self.interrupted = false
                    self.recoveryTask?.cancel(); self.recoveryTask = nil
                    if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                        self.requestRecovery()
                    } else {
                        self.onAvailabilityChanged?(.failed("Audio interruption ended without permission to resume. Start a new call."))
                    }
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.callID == id else { return }
                self.setCaptureEnabled(false)
                self.onAvailabilityChanged?(.recovering)
                guard self.callID == id else { return }
                // Media services reset orphans native objects. Discard them
                // rather than querying or reconfiguring invalid I/O nodes.
                self.graphID = UUID()
                if let observer = self.engineObserver { center.removeObserver(observer) }
                self.engineObserver = nil
                self.tapInstalled = false
                self.invalidatePlayback()
                self.engine = AVAudioEngine()
                self.player = AVAudioPlayerNode()
                // QA1749 requires a new user action before reactivation.
                self.onAvailabilityChanged?(.failed("Audio services restarted. Tap the pet to start a new call."))
            }
        })
    }

    @MainActor
    private func requestRecovery() {
        guard let id = callID else { return }
        routeRevision &+= 1
        setCaptureEnabled(false)
        if !interrupted { onAvailabilityChanged?(.recovering) }
        guard callID == id else { return }
        // No graph mutation from the native notification's internal queue.
        invalidatePlayback()
        player.stop()
        engine.stop()
        guard !interrupted else { return }
        guard recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(8))
            do {
                try self.tearDownGraph()
                guard ContinuousClock.now.advanced(by: .seconds(2)) < deadline else {
                    throw NSError(domain: "RealtimeAudio", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Audio recovery budget exhausted. Start a new call."])
                }
                try await self.onInputSuspensionChanged?(true)
                for attempt in 0..<3 {
                    try Task.checkCancellation()
                    guard self.callID == id, !self.interrupted else { return }
                    let revision = self.routeRevision
                    try await Task.sleep(for: .milliseconds([100, 250, 500][attempt]))
                    try Task.checkCancellation()
                    guard self.callID == id, !self.interrupted else { return }
                    guard clock.now < deadline else { break }
                    do {
                        try self.startGraph()
                        guard clock.now.advanced(by: .seconds(2)) < deadline else { break }
                        try await self.onInputSuspensionChanged?(false)
                        try Task.checkCancellation()
                        guard self.callID == id, !self.interrupted else { return }
                        if self.routeRevision == revision && self.engine.isRunning && clock.now < deadline {
                            self.openCaptureGate()
                            self.recoveryTask = nil
                            self.onAvailabilityChanged?(.available)
                            return
                        }
                        // A new route arrived while awaiting unmute. Pause again
                        // before rebuilding; never reopen capture for that graph.
                        guard clock.now.advanced(by: .seconds(2)) < deadline else { break }
                        try await self.onInputSuspensionChanged?(true)
                    } catch is CancellationError {
                        if Task.isCancelled { return }
                        throw CancellationError()
                    }
                    catch {
                        rtAudioLog.error("audio recovery attempt: \(error.localizedDescription, privacy: .public)")
                        if attempt == 2 { throw error }
                    }
                    try self.tearDownGraph()
                }
                throw NSError(domain: "RealtimeAudio", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Audio recovery budget exhausted. Start a new call."])
            } catch {
                guard self.callID == id, !Task.isCancelled else { return }
                self.recoveryTask = nil
                self.stop()
                self.onAvailabilityChanged?(.failed(error.localizedDescription))
            }
        }
    }

    @MainActor
    private func tearDownGraph() throws {
        graphID = UUID()
        if let observer = engineObserver { NotificationCenter.default.removeObserver(observer) }
        engineObserver = nil
        setCaptureEnabled(false)
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        invalidatePlayback()
        player.stop()
        engine.stop()
        if engine.inputNode.isVoiceProcessingEnabled {
            try engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
    }

    @MainActor
    func stop() {
        guard let id = callID else { return }
        callID = nil
        recoveryTask?.cancel(); recoveryTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        do { try tearDownGraph() }
        catch {
            let message = "Couldn't release voice processing: \(error.localizedDescription)"
            rtAudioLog.error("\(message, privacy: .public)")
            onCleanupError?(message)
        }
        do {
            try VoiceAudioSessionOwnership.shared.release(owner: id) {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            let message = "Couldn't release audio session: \(error.localizedDescription)"
            rtAudioLog.error("\(message, privacy: .public)")
            onCleanupError?(message)
            // A newer call takes ownership synchronously and makes the old
            // bounded cleanup retry a no-op, even if its own activation fails.
            cleanupTask = Task { @MainActor in
                for _ in 0..<2 {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    do {
                        try VoiceAudioSessionOwnership.shared.release(owner: id) {
                            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                        }
                        return
                    } catch { rtAudioLog.error("audio session release retry: \(error.localizedDescription, privacy: .public)") }
                }
            }
        }
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
        guard callID != nil, recoveryTask == nil, !interrupted else { return }
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

    private func captureFailed(_ generation: UInt64) {
        captureLock.lock()
        guard captureEnabled, captureGeneration == generation else { captureLock.unlock(); return }
        captureEnabled = false
        captureLock.unlock()
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentCaptureGeneration(generation) else { return }
            self.requestRecovery()
        }
    }

    private func isCurrentCaptureGeneration(_ generation: UInt64) -> Bool {
        captureLock.lock(); defer { captureLock.unlock() }
        return captureGeneration == generation
    }

    private func captureAndForward(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                                   generation: UInt64, callback: (@Sendable (Data, UInt64) -> Void)?) {
        guard isCaptureCurrent(generation) else { return }
        guard buffer.format == converter.inputFormat else { captureFailed(generation); return }
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
        if let error { rtAudioLog.error("convert: \(error.localizedDescription, privacy: .public)"); captureFailed(generation); return }
        guard out.frameLength > 0, let chan = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: chan, count: Int(out.frameLength) * 2)
        guard isCaptureCurrent(generation) else { return }
        callback?(data, generation)
    }
}

extension RealtimeAudioIO: VoiceCallAudio {}
