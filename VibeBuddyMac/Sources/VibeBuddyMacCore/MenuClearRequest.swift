import Foundation
import VibeBuddyKit

/// A menu action binds to the source and visible rounds the user actually saw.
/// Applying it changes only local menu preferences, never the underlying snapshot.
public struct MenuClearRequest: Sendable {
    private let sourceID: String?
    private let targets: [AgentSession]
    private let roundIDs: [String: String]

    public var count: Int { targets.count }
    public var isAvailable: Bool { sourceID != nil && !targets.isEmpty }

    public init(_ sessions: [AgentSession], preferences: MenuSessionPreferences,
                sourceID: String?, roundIDs: [String: String] = [:]) {
        self.sourceID = sourceID.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.roundIDs = roundIDs
        targets = preferences.visible(sessions, sourceID: sourceID, roundIDs: roundIDs).filter {
            $0.presentationState == .completeUnread || $0.presentationState == .idle
        }
    }

    public func apply(to preferences: inout MenuSessionPreferences, currentSessions: [AgentSession],
                      currentSourceID: String?, currentRoundIDs: [String: String] = [:]) {
        guard let sourceID, sourceID == currentSourceID else { return }
        preferences.clear(targets, currentSessions: currentSessions, sourceID: sourceID,
                          roundIDs: roundIDs, currentRoundIDs: currentRoundIDs)
    }
}
