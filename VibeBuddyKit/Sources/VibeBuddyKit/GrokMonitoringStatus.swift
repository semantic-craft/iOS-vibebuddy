import Foundation

/// Discovery is not task progress. These rows never enter the session reducer,
/// notifications or remote-control paths before Grok reports a real event.
public struct GrokDiscoveredSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var cwd: String?
    public init(id: String, cwd: String?) { self.id = id; self.cwd = cwd }
    public var project: String { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Grok Build" }
}

public struct GrokMonitoringStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var configured: Bool
    public var available: Bool
    public var error: String?
    public var connectedSessionCount: Int
    public var discoveredSessions: [GrokDiscoveredSession]

    /// Reload helps only an observed session whose reporting hooks are ready.
    public var needsHookReload: Bool {
        enabled && available && configured && error == nil && !discoveredSessions.isEmpty
    }

    public init(enabled: Bool, configured: Bool, available: Bool, error: String? = nil,
                connectedSessionCount: Int, discoveredSessions: [GrokDiscoveredSession]) {
        self.enabled = enabled; self.configured = configured; self.available = available
        self.error = error; self.connectedSessionCount = connectedSessionCount
        self.discoveredSessions = discoveredSessions
    }
}
