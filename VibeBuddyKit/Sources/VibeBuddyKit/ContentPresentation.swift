import Foundation

public enum ContentPresentationTarget: Codable, Hashable, Sendable {
    case completion(sessionID: String, completionID: String)
    case waiting(sessionID: String, kind: String, pendingID: String?, since: Date)
    case failure(sessionID: String, since: Date)

    public init?(session: AgentSession) {
        if session.status == .needsResponse {
            self = .waiting(sessionID: session.id, kind: session.waitKind?.rawValue ?? "unknown",
                            pendingID: session.pendingApproval?.id ?? session.pendingQuestion?.id,
                            since: session.statusSince)
        } else if session.status == .done, session.isStuck {
            self = .failure(sessionID: session.id, since: session.statusSince)
        } else if session.status == .done, let completionID = session.completionID {
            self = .completion(sessionID: session.id, completionID: completionID)
        } else { return nil }
    }

    public func matches(_ session: AgentSession) -> Bool { Self(session: session) == self }
}

public struct ContentPresentationRequest: Codable, Hashable, Sendable {
    public let sourceID: String
    public let target: ContentPresentationTarget
    public let purpose: SummaryPurpose

    public init(sourceID: String, target: ContentPresentationTarget, purpose: SummaryPurpose = .speech) {
        self.sourceID = sourceID; self.target = target; self.purpose = purpose
    }
}

public struct ContentPresentation: Codable, Hashable, Sendable {
    public let request: ContentPresentationRequest
    public let revision: String
    public let text: String
    public let generated: Bool

    public init(request: ContentPresentationRequest, revision: String, text: String, generated: Bool) {
        self.request = request; self.revision = revision; self.text = text; self.generated = generated
    }
}

public struct ContentStyleState: Codable, Hashable, Sendable {
    public let sourceID: String
    public let configuration: ContentStyleConfiguration
    public let revision: String

    public init(sourceID: String, configuration: ContentStyleConfiguration, revision: String) {
        self.sourceID = sourceID; self.configuration = configuration; self.revision = revision
    }
}

public struct ContentStyleUpdate: Codable, Hashable, Sendable {
    public let sourceID: String
    public let configuration: ContentStyleConfiguration
    public let expectedRevision: String

    public init(sourceID: String, configuration: ContentStyleConfiguration, expectedRevision: String) {
        self.sourceID = sourceID; self.configuration = configuration; self.expectedRevision = expectedRevision
    }
}
