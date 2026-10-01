import Foundation
import Security

public enum CompanionTransportError: Error, Equatable, LocalizedError {
    case invalidAddress, credentialsUnavailable, credentialOriginMismatch, authentication, keychainWriteFailed
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a valid HTTPS address."
        case .credentialsUnavailable: return "Cloudflare credentials are unavailable. Unlock your iPhone or update the credentials."
        case .credentialOriginMismatch: return "These credentials belong to a different Cloudflare address."
        case .authentication: return "Connection authentication was refused. Check Cloudflare Access and your Mac pairing."
        case .keychainWriteFailed: return "Could not save Cloudflare credentials securely. Your previous connection is unchanged."
        }
    }
}

public struct CloudflareCredentials: Codable, Sendable, Equatable {
    public let origin: String
    public let clientID: String
    public let clientSecret: String

    public init?(origin: String, clientID: String, clientSecret: String) {
        guard let origin = Self.normalizedOrigin(origin),
              Self.validHeader(clientID), Self.validHeader(clientSecret) else { return nil }
        self.origin = origin
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    private static func validHeader(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 33 && $0 <= 126 }
    }

    public static func normalizedOrigin(_ value: String) -> String? {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.port == nil || parts.port == 443,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              let rawHost = parts.host, let host = CompanionEndpoint.normalizedHost(rawHost) else { return nil }
        return "https://\(host)"
    }
}

public enum CloudflareCredentialStore {
    private static func key(_ id: String) -> String { "cloudflare.\(id)" }
    @discardableResult
    public static func save(_ credentials: CloudflareCredentials, id: String = UUID().uuidString,
                            operations: KeychainStore.Operations = .live) throws -> String {
        guard !id.isEmpty, let value = String(data: try JSONEncoder().encode(credentials), encoding: .utf8),
              KeychainStore.set(value, for: key(id), operations: operations) == errSecSuccess else {
            throw CompanionTransportError.keychainWriteFailed
        }
        return id
    }
    public static func load(id: String, operations: KeychainStore.Operations = .live) throws -> CloudflareCredentials {
        guard let value = KeychainStore.get(key(id), operations: operations),
              let data = value.data(using: .utf8), let stored = try? JSONDecoder().decode(CloudflareCredentials.self, from: data),
              let validated = CloudflareCredentials(origin: stored.origin, clientID: stored.clientID, clientSecret: stored.clientSecret) else {
            throw CompanionTransportError.credentialsUnavailable
        }
        return validated
    }
    public static func delete(id: String, operations: KeychainStore.Operations = .live) throws {
        guard KeychainStore.set(nil, for: key(id), operations: operations) == errSecSuccess else {
            throw CompanionTransportError.keychainWriteFailed
        }
    }
}

/// One origin-bound boundary for every native phone-to-Mac request, including WS.
public enum CompanionTransport {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    public static func prepare(_ request: URLRequest, pairing: PairingPayload,
                               credentials: CloudflareCredentials? = nil) throws -> URLRequest {
        guard pairing.isValidConnection, let endpoint = pairing.endpoint,
              let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.host?.lowercased() == endpoint.host,
              (parts.port ?? (endpoint.usesTLS ? 443 : 80)) == endpoint.port,
              (endpoint.usesTLS ? ["https", "wss"] : ["http", "ws"]).contains(parts.scheme ?? "") else {
            throw CompanionTransportError.invalidAddress
        }
        var result = request
        result.setValue(nil, forHTTPHeaderField: "CF-Access-Client-Id")
        result.setValue(nil, forHTTPHeaderField: "CF-Access-Client-Secret")
        result.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        if let id = pairing.cloudflareCredentialID {
            let stored = try credentials ?? CloudflareCredentialStore.load(id: id)
            guard stored.origin == "https://\(endpoint.host)" else { throw CompanionTransportError.credentialOriginMismatch }
            result.setValue(stored.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
            result.setValue(stored.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return result
    }

    public static func data(for request: URLRequest, pairing: PairingPayload, credentials: CloudflareCredentials? = nil) async throws -> (Data, URLResponse) {
        let response = try await session.data(for: prepare(request, pairing: pairing, credentials: credentials))
        if pairing.isCloudflare { try validateCloudflareResponse(response.1) }
        return response
    }

    public static func validateCloudflareResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CompanionTransportError.authentication }
        if (300...399).contains(http.statusCode) || http.statusCode == 401 || http.statusCode == 403
            || ((200...299).contains(http.statusCode) && http.mimeType?.lowercased() == "text/html") {
            throw CompanionTransportError.authentication
        }
    }

    public static func webSocketTask(with request: URLRequest, pairing: PairingPayload, credentials: CloudflareCredentials? = nil) throws -> URLSessionWebSocketTask {
        session.webSocketTask(with: try prepare(request, pairing: pairing, credentials: credentials))
    }
}
