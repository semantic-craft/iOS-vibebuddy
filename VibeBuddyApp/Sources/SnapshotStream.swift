import Foundation
import VibeBuddyKit

/// Streams live snapshots. Injectable so the dashboard can be driven by a fake.
protocol SnapshotStreaming: Sendable {
    /// Yields snapshots until the connection drops; the stream then finishes so
    /// the caller can reconnect.
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error>
}

enum CompanionConnectionFailure: Error {
    case invalidAddress
    case authentication
}

/// WebSocket client with a bounded heartbeat, following HAKit's liveness check.
/// Finishing the stream lets DashboardStore's existing reconnect loop recover.
struct WebSocketSnapshotClient: SnapshotStreaming {
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> {
        AsyncThrowingStream { continuation in
            let providers = AccountUsageProvider.allCases.map(\.rawValue).joined(separator: ",")
            guard let url = pairing.companionURL(path: "ws", webSocket: true, queryItems: [URLQueryItem(name: "quotaProviders", value: providers)]) else {
                continuation.finish(throwing: CompanionConnectionFailure.invalidAddress); return
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            let task = Task {
                socket.resume()
                let firstSnapshotDeadline = Task {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    continuation.finish(throwing: URLError(.timedOut))
                    socket.cancel(with: .goingAway, reason: nil)
                }
                var heartbeat: Task<Void, Never>?
                defer {
                    firstSnapshotDeadline.cancel()
                    heartbeat?.cancel()
                    socket.cancel(with: .goingAway, reason: nil)
                    continuation.finish()
                }
                while !Task.isCancelled {
                    do {
                        let message = try await socket.receive()
                        if heartbeat == nil { heartbeat = Self.monitor(socket) }
                        guard case let .string(text) = message,
                              let data = text.data(using: .utf8),
                              let event = try? JSONDecoder().decode(ServerEvent.self, from: data)
                        else { continue }
                        if case let .snapshot(snapshot) = event {
                            firstSnapshotDeadline.cancel()
                            continuation.yield(snapshot)
                        }
                    } catch {
                        if let status = (socket.response as? HTTPURLResponse)?.statusCode,
                           status == 401 || status == 403 {
                            continuation.finish(throwing: CompanionConnectionFailure.authentication)
                        } else {
                            continuation.finish(throwing: error)
                        }
                        break
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                // Cancelling a Swift task alone must not leave receive() and
                // an authenticated subscription alive on the previous server.
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private static func monitor(_ socket: URLSessionWebSocketTask) -> Task<Void, Never> {
        Task {
            // Start only after the first received frame confirms the handshake.
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            while !Task.isCancelled {
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { return }
                    socket.cancel(with: .goingAway, reason: nil)
                }
                defer { deadline.cancel() }
                socket.sendPing { error in
                    deadline.cancel()
                    if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                }
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
    }

}
