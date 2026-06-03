import Foundation
import VibeBuddyKit

/// Consumes the live snapshot stream and publishes grouped sessions, connection
/// state, and notifications. Reconnects automatically when the socket drops.
@MainActor
final class DashboardStore: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var groups = SessionGroups([])
    @Published private(set) var state: ConnectionState = .connecting

    private let streamer: SnapshotStreaming
    private let notifier: AttentionNotifier
    private let liveActivity = LiveActivityManager()
    private var runTask: Task<Void, Never>?
    private var lastSessions: [AgentSession] = []
    private var seenFirstSnapshot = false

    init(streamer: SnapshotStreaming = WebSocketSnapshotClient(),
         notifier: AttentionNotifier = LocalNotifier()) {
        self.streamer = streamer
        self.notifier = notifier
        notifier.requestAuthorization()
    }

    func start(_ pairing: PairingPayload) {
        stop()
        state = .connecting
        lastSessions = []
        seenFirstSnapshot = false
        runTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for await snapshot in self.streamer.stream(pairing) {
                    if Task.isCancelled { return }
                    await self.apply(snapshot)
                }
                if Task.isCancelled { return }
                self.state = .failed("连接断开,重连中…")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        Task { await liveActivity.end() }
    }

    private func apply(_ snapshot: Snapshot) async {
        // Notify only on a fresh transition into needsResponse; lastSessions
        // persists across reconnects so the already-waiting set isn't re-fired.
        if seenFirstSnapshot {
            for session in AttentionDiff.newlyNeedingResponse(
                old: lastSessions, new: snapshot.sessions) {
                notifier.notify(session)
            }
        }
        lastSessions = snapshot.sessions
        seenFirstSnapshot = true
        groups = SessionGroups(snapshot.sessions)
        state = .connected
        await liveActivity.sync(
            needsResponse: groups.needsResponse.count,
            working: groups.working.count,
            done: groups.done.count,
            topProject: groups.needsResponse.first?.project)
    }
}
