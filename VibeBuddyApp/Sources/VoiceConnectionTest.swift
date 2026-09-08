import Foundation
import Combine
import VibeBuddyKit

/// Owns only the iPhone Settings handshake, never the Buddy conversation.
@MainActor
final class VoiceConnectionTest: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var session: (any RealtimeVoiceProvider)?

    func start(_ session: any RealtimeVoiceProvider, voice: String) {
        guard !busy else { return }
        let id = UUID(); generation = id
        self.session = session; busy = true; message = "Testing connection…"
        worker = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let stream = await session.start(instructions: "This is a configuration check. Stay silent. No audio or task actions are requested.", voice: voice, tools: [])
            guard !Task.isCancelled else { await session.close(); return }
            var result = "The connection ended without confirming configuration."
            for await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .connected: result = "Realtime connection configuration confirmed. Audio and conversation were not tested."
                case .failed: result = "Realtime connection failed. Check the API key, model, voice, region and network before retrying."
                case .closed: result = "The connection ended without confirming configuration."
                default: continue
                }
                break
            }
            await session.close()
            guard let self, self.generation == id, !Task.isCancelled else { return }
            self.timer?.cancel(); self.timer = nil
            self.session = nil; self.worker = nil; self.busy = false; self.message = result
        }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.generation == id else { return }
            self.stop(message: "Test timed out. Check your connection and configuration, then retry manually.")
        }
    }
    func invalidate() { stop(message: nil) }
    func cancel() { stop(message: "Test cancelled.") }
    private func stop(message: String?) {
        generation = UUID(); self.message = message
        timer?.cancel(); timer = nil
        guard busy, cleanup == nil else { return }
        worker?.cancel()
        let worker = worker, session = session
        cleanup = Task { [weak self] in
            await session?.close()
            await worker?.value
            guard let self else { return }
            self.worker = nil; self.session = nil; self.cleanup = nil; self.busy = false
        }
    }
}
