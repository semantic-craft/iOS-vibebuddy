import Foundation

/// LAN, Tailscale and Headscale share the existing HTTP/WS transport.
/// This validates an address, not whether a VPN is installed or reachable.
public struct CompanionEndpoint: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let usesTLS: Bool

    public init?(host: String, port: Int, usesTLS: Bool = false) {
        guard (1...65535).contains(port), let host = Self.normalizedHost(host) else { return nil }
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
    }

    /// The address check without a port: trims, lower-cases, and answers nil
    /// for anything that cannot be a hostname at all. A caller that persists a
    /// host uses this to drop a stored value instead of advertising it, since
    /// a pairing payload carrying a garbage host reaches the phone as nothing
    /// more legible than an unreachable Mac.
    public static func normalizedHost(_ host: String) -> String? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            guard labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) else { return nil }
        }
        return host
    }

    public var isTailscale: Bool {
        !usesTLS && (host.hasSuffix(".ts.net") || isTailnetIPv4)
    }

    /// Headscale's usual private range, independent of its custom DNS suffix.
    public var isTailnetIPv4: Bool {
        let labels = host.split(separator: ".")
        guard labels.count == 4 else { return false }
        let parts = labels.compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Addresses eligible for an authenticated handoff to the same Mac.
    /// Deliberately excludes public, loopback, link-local and DNS destinations.
    public var isPrivateConnectionIPv4: Bool {
        if isTailnetIPv4 { return true }
        let labels = host.split(separator: ".")
        let parts = labels.compactMap { UInt8($0) }
        guard labels.count == 4, parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
    }

    public func url(path: String, webSocket: Bool = false, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = usesTLS ? (webSocket ? "wss" : "https") : (webSocket ? "ws" : "http")
        components.host = host
        components.port = port
        components.path = "/" + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }
}

public extension PairingPayload {
    /// Change the route to the same Mac without asking for its bearer again.
    /// Use an IP so custom Headscale DNS does not require a global ATS exception.
    func usingTailnetIPv4(_ host: String, port: Int) -> PairingPayload? {
        guard let endpoint = CompanionEndpoint(host: host, port: port), endpoint.isTailnetIPv4 else { return nil }
        var result = self
        result.cloudflareCredentialID = nil
        result.host = endpoint.host
        result.port = endpoint.port
        return result.isValidConnection ? result : nil
    }

    /// Shared LAN/tailnet handoff; the receiver must still verify sourceID
    /// and the current proposal before persisting this candidate.
    func usingPrivateConnectionIPv4(_ host: String, port: Int) -> PairingPayload? {
        guard let endpoint = CompanionEndpoint(host: host, port: port), endpoint.isPrivateConnectionIPv4 else { return nil }
        var result = self
        result.cloudflareCredentialID = nil
        result.host = endpoint.host
        result.port = endpoint.port
        return result.isValidConnection ? result : nil
    }

    var isCloudflare: Bool { cloudflareCredentialID != nil }
    func usingCloudflare(origin: String, credentialID: String) -> PairingPayload? {
        guard let origin = CloudflareCredentials.normalizedOrigin(origin),
              let host = URLComponents(string: origin)?.host, !credentialID.isEmpty else { return nil }
        var result = self
        result.host = host
        result.port = 443
        result.cloudflareCredentialID = credentialID
        return result.isValidConnection ? result : nil
    }
    var endpoint: CompanionEndpoint? {
        guard !isCloudflare || (port == 443 && cloudflareCredentialID?.isEmpty == false) else { return nil }
        return CompanionEndpoint(host: host, port: port, usesTLS: isCloudflare)
    }
    var isValidConnection: Bool {
        endpoint != nil && !token.isEmpty && !token.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    func companionURL(path: String, webSocket: Bool = false, queryItems: [URLQueryItem] = []) -> URL? {
        guard isValidConnection else { return nil }
        return endpoint?.url(path: path, webSocket: webSocket, queryItems: queryItems)
    }
}
