import Foundation

public struct RemoteConnectionProposal: Codable, Equatable, Sendable {
    public var requestID: String
    public var deviceID: String
    public var sourceID: String
    public var host: String
    public var port: Int
    public var expiresAt: Date

    public init(requestID: String, deviceID: String, sourceID: String, host: String, port: Int, expiresAt: Date) {
        self.requestID = requestID
        self.deviceID = deviceID
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.expiresAt = expiresAt
    }
}

public struct RemoteConnectionReceipt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case received, confirmed, unreachable, unauthorized, cancelled
    }

    public var requestID: String
    public var deviceID: String
    public var sourceID: String
    public var outcome: Outcome

    public init(requestID: String, deviceID: String, sourceID: String, outcome: Outcome) {
        self.requestID = requestID
        self.deviceID = deviceID
        self.sourceID = sourceID
        self.outcome = outcome
    }
}
