import Foundation

/// Asks the local daemon to write its tool ledger before `facts` reads it.
/// Best effort with a short deadline: no daemon, no token or a slow answer
/// just means facts reads whatever is on disk. Skipped when the facts
/// directory is overridden, because then the daemon is not its writer.
enum LedgerFlushRequest {
    static let timeout: TimeInterval = 0.3

    static func send(environment: [String: String]) async {
        guard environment["VIBEBUDDY_FACTS_DIRECTORY"] == nil else { return }
        let port = environment["VIBEBUDDY_PORT"].flatMap(Int.init) ?? 9876
        guard (1...65535).contains(port),
              let token = environment["VIBEBUDDY_TOKEN"] ?? TokenStore.defaultStore().load(),
              !token.isEmpty, !token.contains(where: { $0.isNewline }),
              let url = URL(string: "http://127.0.0.1:\(port)/ledger/flush") else { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }
}
