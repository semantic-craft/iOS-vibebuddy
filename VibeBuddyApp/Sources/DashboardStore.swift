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
    private var pollTask: Task<Void, Never>?

    init(client: SnapshotFetching = HTTPSnapshotClient()) {
        self.client = client
    }

    func start(_ pairing: PairingPayload, interval: Duration = .seconds(2)) {
        stop()
        state = .connecting
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let snapshot = try await self.client.fetch(pairing)
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
