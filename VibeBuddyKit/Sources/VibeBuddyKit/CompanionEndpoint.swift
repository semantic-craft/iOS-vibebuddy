import Foundation

/// LAN, Tailscale and Headscale share the existing HTTP/WS transport.
/// This validates an address, not whether a VPN is installed or reachable.
public struct CompanionEndpoint: Sendable, Equatable {
    public let host: String
    public let port: Int

    public init?(host: String, port: Int) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1...65535).contains(port), !host.isEmpty, host.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            guard labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) else { return nil }
        }
        self.host = host
        self.port = port
    }

    public var isTailscale: Bool {
        host.hasSuffix(".ts.net") || isTailnetIPv4
    }

    /// Headscale's usual private range, independent of its custom DNS suffix.
    public var isTailnetIPv4: Bool {
        let labels = host.split(separator: ".")
        guard labels.count == 4 else { return false }
        let parts = labels.compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    public func url(path: String, webSocket: Bool = false, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = webSocket ? "ws" : "http"
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
        result.host = endpoint.host
        result.port = endpoint.port
        return result.isValidConnection ? result : nil
    }

    var endpoint: CompanionEndpoint? { CompanionEndpoint(host: host, port: port) }
    var isValidConnection: Bool {
        endpoint != nil && !token.isEmpty && !token.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    func companionURL(path: String, webSocket: Bool = false, queryItems: [URLQueryItem] = []) -> URL? {
        guard isValidConnection else { return nil }
        return endpoint?.url(path: path, webSocket: webSocket, queryItems: queryItems)
    }
}
