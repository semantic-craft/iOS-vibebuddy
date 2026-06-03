import Foundation
import VibeBuddyKit

/// Polls the Mac for snapshots and publishes grouped sessions + connection state.
@MainActor
final class DashboardStore: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var groups = SessionGroups([])
    @Published private(set) var state: ConnectionState = .connecting

    private let client: SnapshotFetching
    private let notifier: AttentionNotifier
    private var pollTask: Task<Void, Never>?
    private var lastSessions: [AgentSession] = []
    private var seenFirstSnapshot = false

    init(client: SnapshotFetching = HTTPSnapshotClient(),
         notifier: AttentionNotifier = LocalNotifier()) {
        self.client = client
        self.notifier = notifier
        notifier.requestAuthorization()
    }

    func start(_ pairing: PairingPayload, interval: Duration = .seconds(2)) {
        stop()
        state = .connecting
        lastSessions = []
        seenFirstSnapshot = false
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let snapshot = try await self.client.fetch(pairing)
                    // Notify only on a fresh transition into needsResponse,
                    // and never for the set already waiting at connect time.
                    if self.seenFirstSnapshot {
                        for session in AttentionDiff.newlyNeedingResponse(
                            old: self.lastSessions, new: snapshot.sessions) {
                            self.notifier.notify(session)
                        }
                    }
                    self.lastSessions = snapshot.sessions
                    self.seenFirstSnapshot = true
                    self.groups = SessionGroups(snapshot.sessions)
                    self.state = .connected
                } catch {
                    self.state = .failed(error.localizedDescription)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}
