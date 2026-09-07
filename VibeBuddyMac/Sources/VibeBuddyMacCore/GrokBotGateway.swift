import Foundation
import VibeBuddyKit

enum GrokBotGatewayError: Error { case invalidResponse, unavailable, unauthorizedOrigin, responseTooLarge }

private final class GrokBotGatewayRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GrokBotGatewayConnection: Sendable {
    let accountScope: String
    let accountIdentity: String
    let baseURL: URL
    let token: String?
    let headers: [String: String]

    static func load() async throws -> Self {
        return try await Task.detached(priority: .utility) {
            // One normal noninteractive Keychain read serves this account-scoped
            // operation. Neither password nor descriptor is cached or persisted.
            let accountData = try Data(contentsOf: GrokBotLocalAccount.storeURL)
            _ = try GrokBotLocalAccount.cacheIdentity(accountData)
            let password = try GrokBotLocalAccount.readSafeStoragePassword()
            let account = try GrokBotLocalAccount.decode(accountData, password: password, now: Date())
            struct DescriptorStore: Decodable {
                struct Entry: Decodable { let savedAtMs: Double; let encrypted: String }
                let version: Int
                let entries: [String: Entry]
            }
            struct Descriptor: Decodable { let baseUrl: String; let token: String?; let headers: [String: String]? }
            let url = GrokBotLocalAccount.storeURL.deletingLastPathComponent().appendingPathComponent("gateway-descriptor.json")
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else { throw GrokBotGatewayError.invalidResponse }
            let store = try JSONDecoder().decode(DescriptorStore.self, from: data)
            guard store.version == 2, let entry = store.entries[account.accountScope], entry.savedAtMs.isFinite,
                  Date().timeIntervalSince1970 * 1000 - entry.savedAtMs < 7 * 86400 * 1000,
                  entry.savedAtMs <= Date().addingTimeInterval(60).timeIntervalSince1970 * 1000 else {
                throw GrokBotGatewayError.unavailable
            }
            let text = try GrokBotLocalAccount.decryptStoredSecret(entry.encrypted, password: password)
            let descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(text.utf8))
            guard let baseURL = URL(string: descriptor.baseUrl), validOrigin(baseURL),
                  try GrokBotLocalAccount.activeIdentity() == account.accountIdentity else {
                throw GrokBotGatewayError.unauthorizedOrigin
            }
            return Self(accountScope: account.accountScope, accountIdentity: account.accountIdentity,
                        baseURL: baseURL, token: descriptor.token, headers: descriptor.headers ?? [:])
        }.value
    }

    /// This is the region actually verified against the current official client.
    /// A newly introduced region fails closed until its origin is verified.
    static func validOrigin(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.hasSuffix(".us9.cursorvm.com") == true
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
    }
    func request(path: String, body: Data? = nil) throws -> URLRequest {
        guard ["api/listAgents", "api/getAgentTranscriptPage", "events"].contains(path), Self.validOrigin(baseURL) else {
            throw GrokBotGatewayError.unauthorizedOrigin
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.allHTTPHeaderFields = headers
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("1", forHTTPHeaderField: "x-sand-slim-avatars")
        request.setValue(body == nil ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = body == nil ? 300 : 20
        return request
    }
}

/// Optional, read-only source. No tasks, approvals or remote read acknowledgements.
public actor GrokBotMonitor {
    private var enabled: Bool
    private let botNames: Set<String>?
    private var connectionSession: URLSession?
    private var knownSessionIDs: Set<String> = []
    private var accountIdentity: String?

    public init(enabled: Bool = false, botNames: Set<String>? = nil) {
        self.enabled = enabled
        self.botNames = botNames
    }
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { connectionSession?.invalidateAndCancel() }
    }
    private func disconnect() { connectionSession?.invalidateAndCancel() }

    public func run(store: SessionStore) async {
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                guard enabled else {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                do { try await observe(store: store) }
                catch {
                    if Task.isCancelled { break }
                    await store.recordSourceSignal(agent: .grokBot, source: .gateway,
                                                   health: .sourceUnreadable, at: Date())
                }
                if !Task.isCancelled { try? await Task.sleep(for: .seconds(5)) }
            }
            disconnect()
        } onCancel: { Task { await self.disconnect() } }
    }

    private func observe(store: SessionStore) async throws {
        await store.recordSourceSignal(agent: .grokBot, source: .gateway, health: .eventsMissing, at: Date())
        guard enabled, !Task.isCancelled else { return }
        let connection = try await GrokBotGatewayConnection.load()
        guard enabled, !Task.isCancelled else { return }
        if let previous = accountIdentity, previous != connection.accountIdentity {
            for id in knownSessionIDs {
                guard enabled, !Task.isCancelled else { return }
                await store.ingest(HookEvent(kind: .sessionEnd, sessionID: id, agent: .grokBot,
                                            observationSource: .gateway, timestamp: Date()))
            }
            knownSessionIDs.removeAll()
        }
        accountIdentity = connection.accountIdentity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 86400
        let session = URLSession(configuration: configuration, delegate: GrokBotGatewayRedirects(), delegateQueue: nil)
        connectionSession = session
        defer { session.invalidateAndCancel(); connectionSession = nil }
        let rosterRequest = try connection.request(path: "api/listAgents", body: Data("{\"allowEmptyRoster\":true}".utf8))
        let (rosterBytes, rosterResponse) = try await session.bytes(for: rosterRequest)
        guard (rosterResponse as? HTTPURLResponse)?.statusCode == 200 else { throw GrokBotGatewayError.unavailable }
        var rosterData = Data()
        for try await byte in rosterBytes {
            guard rosterData.count < 8_388_608 else { throw GrokBotGatewayError.responseTooLarge }
            rosterData.append(byte)
        }
        guard let rawRoster = try JSONSerialization.jsonObject(with: rosterData) as? [[String: Any]] else { throw GrokBotGatewayError.invalidResponse }
        var roster: [GrokBotObservation.Agent] = []
        var malformedRoster = false
        for row in rawRoster.prefix(128) {
            if let botNames, let name = row["name"] as? String, !botNames.contains(name) { continue }
            do { roster.append(try JSONDecoder().decode(GrokBotObservation.Agent.self, from: JSONSerialization.data(withJSONObject: row))) }
            catch { malformedRoster = true }
        }
        // Inspect only a small latest page. Never replay history into live turns.
        // A native widget can be waiting while the roster's awaiting flag is null.
        struct Page: Decodable { let entries: [GrokBotObservation.Entry] }
        var tails: [String: [GrokBotObservation.Entry]] = [:]
        for agent in roster.prefix(128) where (botNames == nil || botNames!.contains(agent.name)) && agent.widgetID != nil {
            do {
                try Task.checkCancellation()
                let body = try JSONSerialization.data(withJSONObject: ["id": agent.id, "limit": 5, "untilMs": Int64(Date().timeIntervalSince1970 * 1000)])
                let (tailBytes, tailResponse) = try await session.bytes(for: connection.request(path: "api/getAgentTranscriptPage", body: body))
                guard (tailResponse as? HTTPURLResponse)?.statusCode == 200 else { throw GrokBotGatewayError.unavailable }
                var tailData = Data()
                for try await byte in tailBytes {
                    guard tailData.count < 1_048_576 else { throw GrokBotGatewayError.responseTooLarge }
                    tailData.append(byte)
                }
                tails[agent.id] = try JSONDecoder().decode(Page.self, from: tailData).entries
            } catch is CancellationError { throw CancellationError() } catch {
                // Roster already proves a read-only widget wait. A damaged tail
                // cannot suppress other bots or turn that wait into completion.
                continue
            }
        }
        var observer = GrokBotObservation(accountScope: connection.accountScope, connectedAt: Date(), botNames: botNames)
        guard try GrokBotLocalAccount.activeIdentity() == connection.accountIdentity else { throw GrokBotGatewayError.unavailable }
        guard enabled, !Task.isCancelled else { return }
        let restored = await store.snapshot(now: Date()).sessions.filter { $0.agent == .grokBot }.map(\.id)
        for id in restored where !id.hasPrefix("grokBot:" + connection.accountScope + ":") {
            guard enabled, !Task.isCancelled else { return }
            await store.ingest(HookEvent(kind: .sessionEnd, sessionID: id, agent: .grokBot,
                                        observationSource: .gateway, timestamp: Date()))
        }
        knownSessionIDs.formUnion(restored.filter { $0.hasPrefix("grokBot:" + connection.accountScope + ":") })
        // Reconnection never moves an existing Session to idle from roster alone.
        for event in observer.baseline(roster, now: Date(), existingSessionIDs: knownSessionIDs, tails: tails) {
            guard enabled, !Task.isCancelled else { return }
            knownSessionIDs.insert(event.sessionID)
            await store.ingest(event)
        }
        guard enabled, !Task.isCancelled else { return }
        if malformedRoster { observer.markUnknownVersion() }
        let (bytes, response) = try await session.bytes(for: connection.request(path: "events"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GrokBotGatewayError.unavailable }
        await store.recordSourceSignal(agent: .grokBot, source: .gateway, health: observer.health, at: Date())
        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard enabled else { return }
            guard byte == 10 else {
                guard line.count < 262_144 else { throw GrokBotGatewayError.responseTooLarge }
                line.append(byte)
                continue
            }
            defer { line.removeAll(keepingCapacity: true) }
            guard line.starts(with: Data("data:".utf8)) else { continue }
            guard try GrokBotLocalAccount.activeIdentity() == connection.accountIdentity else { throw GrokBotGatewayError.unavailable }
            let payload = Data(line.dropFirst(5))
            for event in try observer.receive(payload, now: Date()) {
                guard enabled, !Task.isCancelled else { return }
                knownSessionIDs.insert(event.sessionID)
                await store.ingest(event)
            }
            await store.recordSourceSignal(agent: .grokBot, source: .gateway, health: observer.health, at: Date())
        }
        throw GrokBotGatewayError.unavailable
    }
}
