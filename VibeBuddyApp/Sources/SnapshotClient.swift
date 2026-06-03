import Foundation
import VibeBuddyKit

extension PairingPayload {
    var baseURL: URL? { URL(string: "http://\(host):\(port)") }
}

enum SnapshotError: Error, LocalizedError {
    case badURL
    case unauthorized
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: "Invalid host/port"
        case .unauthorized: "Token rejected"
        case .badStatus(let code): "Server error \(code)"
        }
    }
}

/// Abstracts fetching a snapshot so the dashboard can be driven by a fake in tests.
protocol SnapshotFetching: Sendable {
    func fetch(_ pairing: PairingPayload) async throws -> Snapshot
}

/// REST polling client. WebSocket push (`/ws`) can replace this later without
/// touching the dashboard.
struct HTTPSnapshotClient: SnapshotFetching {
    func fetch(_ pairing: PairingPayload) async throws -> Snapshot {
        guard let base = pairing.baseURL else { throw SnapshotError.badURL }
        var request = URLRequest(url: base.appendingPathComponent("snapshot"))
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SnapshotError.badStatus(-1) }
        guard http.statusCode != 401 else { throw SnapshotError.unauthorized }
        guard http.statusCode == 200 else { throw SnapshotError.badStatus(http.statusCode) }
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }
}
