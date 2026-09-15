import Foundation
import VibeBuddyKit

protocol RemoteConnectionSyncClient: Sendable {
    func proposal(_ pairing: PairingPayload, deviceID: String) async throws -> RemoteSyncPoll
    func receipt(_ receipt: RemoteConnectionReceipt, pairing: PairingPayload) async throws -> RemoteSyncReceiptResult
}

enum RemoteSyncPoll: Sendable {
    case proposal(RemoteConnectionProposal), empty, unconfirmed, unsupported
}

enum RemoteSyncReceiptResult: Sendable {
    case accepted, invalidated
}

struct HTTPRemoteConnectionSyncClient: RemoteConnectionSyncClient {
    func proposal(_ pairing: PairingPayload, deviceID: String) async throws -> RemoteSyncPoll {
        guard let url = pairing.endpoint?.url(path: "connection-sync", queryItems: [URLQueryItem(name: "deviceID", value: deviceID)]) else {
            throw URLError(.badURL)
        }
        let (data, status) = try await send(URLRequest(url: url), pairing: pairing)
        switch status {
        case 200: return .proposal(try JSONDecoder().decode(RemoteConnectionProposal.self, from: data))
        case 204: return .empty
        case 403: return .unconfirmed
        case 404: return .unsupported
        default: throw URLError(.badServerResponse)
        }
    }

    func receipt(_ receipt: RemoteConnectionReceipt, pairing: PairingPayload) async throws -> RemoteSyncReceiptResult {
        guard let url = pairing.companionURL(path: "connection-sync/receipt") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(receipt)
        let (_, status) = try await send(request, pairing: pairing)
        switch status {
        case 200: return .accepted
        case 403, 409: return .invalidated
        default: throw URLError(.badServerResponse)
        }
    }

    private func send(_ request: URLRequest, pairing: PairingPayload) async throws -> (Data, Int) {
        var request = request
        request.timeoutInterval = 15
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response.statusCode)
    }
}

@MainActor
final class RemoteConnectionSyncController: ObservableObject {
    enum Failure: Equatable {
        case unavailable, unauthorized, wrongMac, expired, cancelled, invalidated

        var message: String {
            switch self {
            case .unavailable: String(localized: "Could not reach the remote address. Check your phone’s remote network, then retry.")
            case .unauthorized: String(localized: "The Mac refused this pairing. Scan its current pairing code to update authorization.")
            case .wrongMac: String(localized: "This address returned a different Mac. Your saved connection has not changed.")
            case .expired: String(localized: "This connection update expired. Send it again from your Mac.")
            case .cancelled: String(localized: "The connection check was paused. Retry when you are ready.")
            case .invalidated: String(localized: "This connection update is no longer available. Send it again from your Mac.")
            }
        }
    }

    enum Confirmation: Equatable {
        case pending, confirmed, unavailable
    }

    enum State: Equatable {
        case idle, received, checking, connected(Confirmation), failed(Failure)
    }

    private struct Update {
        let proposal: RemoteConnectionProposal
        let original: PairingPayload
        let candidate: PairingPayload
        var saved = false
        var pendingReceipt: RemoteConnectionReceipt.Outcome? = .received
        var retryRequested = false
    }

    @Published private(set) var state: State = .idle
    private var update: Update?
    private var seenRequests: [String: Date] = [:]
    private let client: any RemoteConnectionSyncClient
    private let streamer: any SnapshotStreaming
    private let deviceID: () -> String?
    private let now: () -> Date
    private var generation = UUID()
    private var activeRun: UUID?

    init(client: any RemoteConnectionSyncClient = HTTPRemoteConnectionSyncClient(),
         streamer: any SnapshotStreaming = WebSocketSnapshotClient(),
         deviceID: String? = nil, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.streamer = streamer
        self.deviceID = { deviceID ?? PushDeviceIdentity.current() }
        self.now = now
    }

    var address: String? { update.map { "\($0.proposal.host):\($0.proposal.port)" } }
    var canRetry: Bool {
        guard case .failed(let failure) = state, let update, update.proposal.expiresAt > now() else { return false }
        return [.unavailable, .cancelled].contains(failure) && !update.saved
    }

    func retry() {
        guard canRetry else { return }
        update?.pendingReceipt = nil
        update?.retryRequested = true
        state = .received
    }

    func run(connection: ConnectionStore, enabled: Bool, currentSourceID: @escaping () -> String?) async {
        guard connection.pairing != nil, !connection.demo else {
            pause()
            update = nil
            state = .idle
            return
        }
        guard enabled else { pause(); return }
        let id = UUID()
        activeRun = id
        defer { if activeRun == id { pause() } }
        while !Task.isCancelled, activeRun == id {
            let supported = await poll(connection: connection, currentSourceID: currentSourceID)
            if !supported { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func pause() {
        generation = UUID()
        activeRun = nil
        if state == .checking || state == .received {
            state = .failed(.cancelled)
            update?.pendingReceipt = .cancelled
            update?.retryRequested = false
        }
    }

    @discardableResult
    func poll(connection: ConnectionStore, currentSourceID: @escaping () -> String?) async -> Bool {
        guard let pairing = connection.pairing, !connection.demo, !Task.isCancelled else { return true }
        guard let deviceID = deviceID(), !deviceID.isEmpty else {
            generation = UUID()
            if state == .checking || state == .received {
                state = .failed(.cancelled)
                update?.pendingReceipt = .cancelled
            }
            return true
        }
        let id = UUID()
        generation = id
        if let update, !owns(update, connection: connection) {
            self.update = nil
            state = .idle
        }
        seenRequests = seenRequests.filter { $0.value > now() }
        if let update, update.proposal.expiresAt <= now() {
            self.update?.pendingReceipt = nil
            self.update?.retryRequested = false
            if update.saved, update.pendingReceipt != nil { state = .connected(.unavailable) }
            else if !update.saved { state = .failed(.expired) }
        }
        if update?.pendingReceipt != nil {
            await deliverReceipt(connection: connection, id: id)
            guard isCurrent(id) else { return true }
        }
        if update?.retryRequested == true {
            update?.retryRequested = false
            await check(connection: connection, currentSourceID: currentSourceID, id: id)
            return true
        }
        if state == .received, let update, update.pendingReceipt == nil, update.proposal.expiresAt > now() {
            await check(connection: connection, currentSourceID: currentSourceID, id: id)
            return true
        }
        do {
            let result = try await client.proposal(pairing, deviceID: deviceID)
            guard isCurrent(id), connection.pairing == pairing, !connection.demo else { return true }
            switch result {
            case .empty, .unconfirmed:
                invalidateUpdate()
                return true
            case .unsupported:
                invalidateUpdate()
                return false
            case .proposal(let proposal):
                if let update, update.proposal != proposal { invalidateUpdate() }
                guard seenRequests[proposal.requestID] == nil else { return true }
                guard !proposal.requestID.isEmpty, proposal.deviceID == deviceID,
                      !proposal.sourceID.isEmpty, proposal.expiresAt > now(),
                      proposal.expiresAt.timeIntervalSince(now()) <= 300,
                      let candidate = pairing.usingTailnetIPv4(proposal.host, port: proposal.port) else { return true }
                seenRequests[proposal.requestID] = proposal.expiresAt
                update = Update(proposal: proposal, original: pairing, candidate: candidate)
                state = .received
                if let source = currentSourceID(), source != proposal.sourceID {
                    fail(.wrongMac, outcome: .unauthorized)
                    await deliverReceipt(connection: connection, id: id)
                    return true
                }
                await deliverReceipt(connection: connection, id: id)
                guard isCurrent(id), update?.pendingReceipt == nil, state == .received else { return true }
                await check(connection: connection, currentSourceID: currentSourceID, id: id)
            }
        } catch { }
        return true
    }

    private func check(connection: ConnectionStore, currentSourceID: () -> String?, id: UUID) async {
        guard let update, owns(update, connection: connection), update.proposal.expiresAt > now(), isCurrent(id) else { return }
        state = .checking
        do {
            let snapshot = try await RemoteConnectionCheck.verify(update.candidate, streamer: streamer)
            guard isCurrent(id), owns(update, connection: connection) else { return }
            guard update.proposal.expiresAt > now() else {
                fail(.expired, outcome: nil)
                return
            }
            guard snapshot.sourceID == update.proposal.sourceID,
                  currentSourceID().map({ $0 == update.proposal.sourceID }) ?? true else {
                fail(.wrongMac, outcome: .unauthorized)
                await deliverReceipt(connection: connection, id: id)
                return
            }
            let latest = try await client.proposal(update.original, deviceID: update.proposal.deviceID)
            guard isCurrent(id), owns(update, connection: connection) else { return }
            guard update.proposal.expiresAt > now() else {
                fail(.expired, outcome: nil)
                return
            }
            guard case .proposal(let current) = latest, current == update.proposal else {
                fail(.invalidated, outcome: nil)
                return
            }
            guard currentSourceID().map({ $0 == update.proposal.sourceID }) ?? true else {
                fail(.wrongMac, outcome: .unauthorized)
                await deliverReceipt(connection: connection, id: id)
                return
            }
            connection.save(update.candidate)
            self.update?.saved = true
            self.update?.pendingReceipt = .confirmed
            state = .connected(.pending)
            await deliverReceipt(connection: connection, id: id)
        } catch {
            guard isCurrent(id), owns(update, connection: connection) else { return }
            if case CompanionConnectionFailure.authentication = error {
                fail(.unauthorized, outcome: .unauthorized)
            } else {
                fail(.unavailable, outcome: .unreachable)
            }
            await deliverReceipt(connection: connection, id: id)
        }
    }

    private func deliverReceipt(connection: ConnectionStore, id: UUID) async {
        guard let update, let outcome = update.pendingReceipt, owns(update, connection: connection),
              update.proposal.expiresAt > now(), isCurrent(id) else { return }
        let receipt = RemoteConnectionReceipt(requestID: update.proposal.requestID, deviceID: update.proposal.deviceID,
                                              sourceID: update.proposal.sourceID, outcome: outcome)
        let routes = update.saved && update.candidate != update.original
            ? [update.candidate, update.original] : [update.original]
        for route in routes {
            do {
                let result = try await client.receipt(receipt, pairing: route)
                guard isCurrent(id), owns(update, connection: connection),
                      self.update?.proposal.requestID == update.proposal.requestID else { return }
                switch result {
                case .accepted:
                    self.update?.pendingReceipt = nil
                    if outcome == .confirmed { state = .connected(.confirmed) }
                case .invalidated:
                    self.update?.pendingReceipt = nil
                    self.update?.retryRequested = false
                    if update.saved { state = .connected(.unavailable) }
                    else { state = .failed(.invalidated) }
                }
                return
            } catch {
                guard isCurrent(id) else { return }
            }
        }
    }

    private func invalidateUpdate() {
        guard let update else { return }
        self.update?.pendingReceipt = nil
        self.update?.retryRequested = false
        if update.saved {
            if state != .connected(.confirmed) { state = .connected(.unavailable) }
        } else if state != .failed(.expired) {
            state = .failed(.invalidated)
        }
    }

    private func fail(_ failure: Failure, outcome: RemoteConnectionReceipt.Outcome?) {
        state = .failed(failure)
        update?.pendingReceipt = outcome
    }

    private func owns(_ update: Update, connection: ConnectionStore) -> Bool {
        !connection.demo && deviceID() == update.proposal.deviceID
            && connection.pairing == (update.saved ? update.candidate : update.original)
    }

    private func isCurrent(_ id: UUID) -> Bool { generation == id && !Task.isCancelled }
}
