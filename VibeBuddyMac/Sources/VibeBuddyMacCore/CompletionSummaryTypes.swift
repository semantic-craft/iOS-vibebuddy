import Foundation

/// Direct mapping boundary for the result-extraction ticket. No transcript reads or lifecycle decisions here.
public struct CompletionSummaryInput: Sendable, Equatable {
    public let sourceID: String
    public let sessionID: String
    public let completionID: String
    public let turnID: String?
    public let title: String
    public let finalText: String
    public let completedAt: Date
    public let observedAt: Date

    public init(sourceID: String, sessionID: String, completionID: String, turnID: String? = nil,
                title: String, finalText: String, completedAt: Date, observedAt: Date) {
        self.sourceID = sourceID; self.sessionID = sessionID; self.completionID = completionID
        self.turnID = turnID; self.title = title; self.finalText = finalText
        self.completedAt = completedAt; self.observedAt = observedAt
    }

    public var identity: CompletionSummaryIdentity {
        .init(sourceID: sourceID, sessionID: sessionID, completionID: completionID)
    }
}

public struct CompletionSummaryIdentity: Hashable, Sendable {
    public let sourceID: String
    public let sessionID: String
    public let completionID: String
    public init(sourceID: String, sessionID: String, completionID: String) {
        self.sourceID = sourceID; self.sessionID = sessionID; self.completionID = completionID
    }
}

/// Safe for diagnostics: never includes provider error bodies, URLs, credentials or input text.
public enum CompletionSummaryFailure: String, Error, Sendable, Equatable {
    case disabled, missingProvider, missingModel, invalidModel, invalidWorkspace, missingKey
    case invalidInput, resultTooLong, duplicate, expired, cancelled
    case network, unauthorized, rateLimited, httpError, invalidResponse, incompleteOutput
    case emptyOutput, outputTooLong, invalidOutput
}

public struct CompletionSummaryUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let cachedInputTokens: Int?
    public let reasoningTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil,
                cachedInputTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens; self.reasoningTokens = reasoningTokens
    }
}

public struct CompletionSummaryResult: Sendable, Equatable {
    public let identity: CompletionSummaryIdentity
    public let text: String?
    public let usage: CompletionSummaryUsage?
    public let failure: CompletionSummaryFailure?
    /// End-to-end age, including final-result wait and queue time; not a provider latency guarantee.
    public let completionLatency: TimeInterval
}

struct CompletionSummaryResponse: Sendable {
    var text: String?
    var usage: CompletionSummaryUsage?
    var failure: CompletionSummaryFailure?
}
