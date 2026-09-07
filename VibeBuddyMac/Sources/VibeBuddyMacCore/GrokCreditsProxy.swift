import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal transport so unit tests can stub the CLI billing proxy without
/// touching the network.
public protocol GrokCreditsProxyTransport: Sendable {
    func proxyData(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GrokCreditsProxyTransport {
    public func proxyData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` — same path
/// CodexBar documents (MIT). Reimplemented against the public HTTP shape; we do
/// not vendor CodexBar's UI stack.
public enum GrokCreditsProxyClient {
    /// Bound the whole transfer, not just idle time between response bytes.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    public static let defaultEndpoint = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    )!

    public static func fetch(
        accessToken: String,
        endpoint: URL = defaultEndpoint,
        transport: GrokCreditsProxyTransport,
        timeout: TimeInterval = 15,
        userAgent: String = "VibeBuddy"
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport.proxyData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AccountUsageError.unknown
        }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw AccountUsageError.notLoggedIn
        case 429:
            throw AccountUsageError.rateLimited
        default:
            throw AccountUsageError.providerUnavailable
        }
    }
}

/// Reads only the access token (and expiry) from `~/.grok/auth.json`. The token
/// itself is never logged.
public enum GrokCLIAuthToken {
    public static let oidcScopePrefix = "https://auth.x.ai::"
    public static let legacySessionScope = "https://accounts.x.ai/sign-in"

    public static func loadAccessToken(from authFileURL: URL, now: Date = Date()) -> String? {
        guard let data = try? Data(contentsOf: authFileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = preferredEntry(in: root) else {
            return nil
        }
        if let expires = entry["expires_at"] as? String,
           let date = parseExpiry(expires),
           now >= date {
            return nil
        }
        if let key = entry["key"] as? String, !key.isEmpty {
            return key
        }
        if let access = entry["access_token"] as? String, !access.isEmpty {
            return access
        }
        return nil
    }

    static func preferredEntry(in root: [String: Any]) -> [String: Any]? {
        let oidc = root
            .compactMap { key, value -> (String, [String: Any])? in
                guard key.hasPrefix(oidcScopePrefix), let entry = value as? [String: Any] else {
                    return nil
                }
                return (key, entry)
            }
            .sorted { $0.0 < $1.0 }
            .first?
            .1
        if let oidc { return oidc }
        return root[legacySessionScope] as? [String: Any]
    }

    private static func parseExpiry(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }
}
