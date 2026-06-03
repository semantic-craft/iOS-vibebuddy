import Foundation

/// Frames pushed from VibeBuddyMac to connected clients over the WebSocket.
/// Codable/Equatable are synthesized for the associated values.
public enum ServerEvent: Codable, Sendable, Equatable {
    case snapshot(Snapshot)
    case sessionUpdated(AgentSession)
    case sessionRemoved(id: String)
}
