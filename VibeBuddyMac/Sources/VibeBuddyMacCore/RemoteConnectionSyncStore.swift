import Foundation
import VibeBuddyKit

public actor RemoteConnectionSyncStore {
    public struct Transfer: Equatable, Sendable {
        public let proposal: RemoteConnectionProposal
        public var outcome: RemoteConnectionReceipt.Outcome?
        public var updatedAt: Date
        public func isExpired(at now: Date) -> Bool { now >= proposal.expiresAt && outcome != .confirmed }
    }

    private var transfers: [String: Transfer] = [:]

    public init() {}

    @discardableResult
    public func propose(deviceID: String, sourceID: String, host: String, port: Int,
                        now: Date = Date()) -> RemoteConnectionProposal? {
        guard !deviceID.isEmpty, !sourceID.isEmpty,
              let endpoint = CompanionEndpoint(host: host, port: port), endpoint.isTailnetIPv4 else { return nil }
        let proposal = RemoteConnectionProposal(requestID: UUID().uuidString, deviceID: deviceID,
            sourceID: sourceID, host: endpoint.host, port: port, expiresAt: now.addingTimeInterval(300))
        transfers[deviceID] = Transfer(proposal: proposal, outcome: nil, updatedAt: now)
        return proposal
    }

    public func pending(for deviceID: String, now: Date = Date()) -> RemoteConnectionProposal? {
        guard let transfer = transfers[deviceID], !transfer.isExpired(at: now),
              transfer.outcome != .confirmed else { return nil }
        return transfer.proposal
    }

    public func transfer(for deviceID: String) -> Transfer? { transfers[deviceID] }

    public func receive(_ receipt: RemoteConnectionReceipt, now: Date = Date()) -> Bool {
        guard var transfer = transfers[receipt.deviceID],
              transfer.proposal.requestID == receipt.requestID,
              transfer.proposal.sourceID == receipt.sourceID else { return false }
        if transfer.outcome == receipt.outcome { return receipt.outcome == .confirmed || !transfer.isExpired(at: now) }
        guard !transfer.isExpired(at: now), transfer.outcome != .confirmed else { return false }
        if receipt.outcome == .received, transfer.outcome != nil { return true }
        if transfer.outcome != nil && transfer.outcome != .received && receipt.outcome != .confirmed { return false }
        transfer.outcome = receipt.outcome
        transfer.updatedAt = now
        transfers[receipt.deviceID] = transfer
        return true
    }

    public func cancel(for deviceID: String) { transfers.removeValue(forKey: deviceID) }
    public func cancelAll() { transfers.removeAll() }
}
