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
    /// The persona of the device that will read the text: the wording is half
    /// of a persona, and the phone and the Mac each keep their own. Absent on
    /// the wire for `.standard`, so a request without a style is unchanged.
    public let voiceStyle: VoiceStyle

    public init(sourceID: String, target: ContentPresentationTarget, purpose: SummaryPurpose = .speech,
                voiceStyle: VoiceStyle = .standard) {
        self.sourceID = sourceID; self.target = target; self.purpose = purpose; self.voiceStyle = voiceStyle
    }

    private enum CodingKeys: String, CodingKey { case sourceID, target, purpose, voiceStyle }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        target = try c.decode(ContentPresentationTarget.self, forKey: .target)
        purpose = try c.decode(SummaryPurpose.self, forKey: .purpose)
        // A persona from a newer peer reads as `.standard` rather than failing
        // the whole request.
        voiceStyle = VoiceStyle(stored: try c.decodeIfPresent(String.self, forKey: .voiceStyle))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(target, forKey: .target)
        try c.encode(purpose, forKey: .purpose)
        if voiceStyle != .standard { try c.encode(voiceStyle.rawValue, forKey: .voiceStyle) }
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
