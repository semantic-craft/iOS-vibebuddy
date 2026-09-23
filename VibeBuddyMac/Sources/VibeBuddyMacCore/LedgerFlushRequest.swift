import Foundation

/// Asks the local daemon to write its tool ledger before `facts` reads it.
/// Best effort with a short deadline: no daemon, no token or a slow answer
/// just means facts reads whatever is on disk. Skipped when the facts
/// directory is overridden, because then the daemon is not its writer, and
/// when `VIBEBUDDY_PORT` is not a valid port.
enum LedgerFlushRequest {
    static let timeout: TimeInterval = 0.3

    static func send(environment: [String: String]) async {
        guard let request = request(environment: environment) else { return }
        let session = LocalDaemonHTTP.session(timeout: timeout)
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(for: request)
    }

    static func request(environment: [String: String]) -> URLRequest? {
        guard environment["VIBEBUDDY_FACTS_DIRECTORY"] == nil,
              let port = LocalDaemonHTTP.port(environment),
              let token = LocalDaemonHTTP.token(environment),
              let url = URL(string: "http://127.0.0.1:\(port)/ledger/flush") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }
}
