import Foundation

/// What a CLI-side client (`vibebuddy-mcp`) needs to call the local daemon:
/// the port from `VIBEBUDDY_PORT`, the bearer token, and a URLSession that
/// talks to 127.0.0.1 only — no proxy, no cookies, no cache, no redirects.
enum LocalDaemonHTTP {
    static let defaultPort = 9876

    /// `VIBEBUDDY_PORT` when it is a valid port, 9876 when it is unset; nil
    /// when it is set to anything else, so a typo never reaches the default
    /// daemon by accident.
    static func port(_ environment: [String: String]) -> Int? {
        guard let value = environment["VIBEBUDDY_PORT"] else { return defaultPort }
        guard let port = Int(value), (1...65535).contains(port) else { return nil }
        return port
    }

    /// `VIBEBUDDY_TOKEN`, else the token file; nil when empty or unusable in a header.
    static func token(_ environment: [String: String]) -> String? {
        guard let token = environment["VIBEBUDDY_TOKEN"] ?? TokenStore.defaultStore().load(),
              !token.isEmpty, !token.contains(where: { $0.isNewline }) else { return nil }
        return token
    }

    static func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
