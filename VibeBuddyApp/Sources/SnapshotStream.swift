import Foundation
import VibeBuddyKit

/// Streams live snapshots. Injectable so the dashboard can be driven by a fake.
protocol SnapshotStreaming: Sendable {
    /// Yields snapshots until the connection drops; the stream then finishes so
    /// the caller can reconnect.
    func stream(_ pairing: PairingPayload) -> AsyncStream<Snapshot>
}

/// WebSocket client: connects to `/ws`, decodes `ServerEvent` frames, yields the
/// snapshot from each. Finishes the stream when the socket closes or errors.
struct WebSocketSnapshotClient: SnapshotStreaming {
    func stream(_ pairing: PairingPayload) -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            let task = Task {
                guard let url = URL(string: "ws://\(pairing.host):\(pairing.port)/ws") else {
                    continuation.finish(); return
                }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
                let socket = URLSession.shared.webSocketTask(with: request)
                socket.resume()

                while !Task.isCancelled {
                    do {
                        let message = try await socket.receive()
                        guard case let .string(text) = message,
                              let data = text.data(using: .utf8),
                              let event = try? JSONDecoder().decode(ServerEvent.self, from: data)
                        else { continue }
                        if case let .snapshot(snapshot) = event {
                            continuation.yield(snapshot)
                        }
                    } catch {
                        break
                    }
                }
                socket.cancel(with: .goingAway, reason: nil)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
