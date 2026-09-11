import Foundation

/// Owned by platform audio I/O. Hardware rebuilds suspend rather than block the
/// main actor; a separate deadline can revoke their right to resume the call.
@MainActor
public final class VoiceAudioRecovery {
    public var onStateChanged: ((VoiceCallAudioState) -> Void)?
    public var canResume = true
    public private(set) var isRecovering = false
    private var active = false
    private var attempt: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private let rebuild: @MainActor () async throws -> Void
    private let release: () -> Void
    private let budget: Duration
    private let interval: Duration

    public convenience init(rebuild: @escaping @MainActor () async throws -> Void, release: @escaping () -> Void) {
        self.init(budget: .seconds(5), interval: .milliseconds(200), rebuild: rebuild, release: release)
    }

    init(budget: Duration, interval: Duration, rebuild: @escaping @MainActor () async throws -> Void,
         release: @escaping () -> Void) {
        self.budget = budget; self.interval = interval
        self.rebuild = rebuild; self.release = release
    }

    public func activate() { active = true }

    public func stop() {
        active = false
        isRecovering = false
        attempt?.cancel(); attempt = nil
        timeout?.cancel(); timeout = nil
        release()
    }

    public func request() {
        guard active, !isRecovering else { return }
        isRecovering = true
        let deadline = ContinuousClock.now.advanced(by: budget)
        release()
        onStateChanged?(.recovering)
        guard active else { return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self, self.active, !Task.isCancelled else { return }
            self.stop()
            self.onStateChanged?(.failed("Audio device recovery timed out. Tap the pet to start a new call."))
        }
        attempt = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await Task.sleep(for: self.interval) } catch { return }
                guard self.active, !Task.isCancelled else { return }
                guard self.canResume else { continue }
                do {
                    try await self.rebuild()
                    guard self.active, !Task.isCancelled else { return }
                    guard self.canResume, ContinuousClock.now < deadline else {
                        self.release()
                        continue
                    }
                    self.isRecovering = false
                    self.attempt = nil
                    self.timeout?.cancel(); self.timeout = nil
                    self.onStateChanged?(.running)
                    return
                } catch {
                    guard self.active, !Task.isCancelled else { return }
                    self.release()
                }
            }
        }
    }
}

/// A queued teardown belongs to one audio operation. Starting or releasing
/// again invalidates its eventual report, without waiting for the hardware.
public final class VoiceAudioReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    public init() {}
    @discardableResult public func advance() -> UUID {
        lock.withLock { generation = UUID(); return generation }
    }
    public func accepts(_ id: UUID) -> Bool { lock.withLock { generation == id } }
}
