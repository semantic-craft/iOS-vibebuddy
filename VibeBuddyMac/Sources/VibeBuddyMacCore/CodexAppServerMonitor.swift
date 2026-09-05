import Foundation
import VibeBuddyKit

/// Keeps one connection to the Codex app-server daemon and feeds its thread,
/// turn and item notifications into the session store as `.appserver`
/// evidence — the primary Codex source while it is fresh (ADR-0011).
///
/// Read-mostly by construction: the only methods ever called are `initialize`,
/// `thread/list`, `thread/resume` (with `excludeTurns`, to subscribe) and
/// `thread/unsubscribe`. It never starts, steers or interrupts a turn, never
/// touches config, and never answers a server-initiated request — those are
/// counted for diagnostics so ticket 03 can see what the daemon routes here.
///
/// The daemon's absence is not an error: the monitor waits for the control
/// socket to appear and the rollout tailer / hooks keep covering Codex until
/// it does. Disabled, it closes its connection and records nothing.
public actor CodexAppServerMonitor {
    public struct Diagnostics: Sendable, Equatable {
        public var enabled: Bool
        public var connected: Bool
        /// The daemon's `userAgent` from `initialize`, e.g. `Codex Desktop/0.145.0 (…)`.
        public var serverUserAgent: String?
        public var lastError: String?
        public var lastEventAt: Date?
        public var subscribedThreads: Int
        /// Methods of server-initiated requests seen on this connection, most
        /// recent last (bounded). Empty means the daemon never routed an
        /// approval or user-input request to a second subscriber.
        public var serverRequestsSeen: [String]

        public init(enabled: Bool = true, connected: Bool = false, serverUserAgent: String? = nil,
                    lastError: String? = nil, lastEventAt: Date? = nil, subscribedThreads: Int = 0,
                    serverRequestsSeen: [String] = []) {
            self.enabled = enabled
            self.connected = connected
            self.serverUserAgent = serverUserAgent
            self.lastError = lastError
            self.lastEventAt = lastEventAt
            self.subscribedThreads = subscribedThreads
            self.serverRequestsSeen = serverRequestsSeen
        }
    }

    private let socketPath: String
    private let makeClient: @Sendable (String) -> CodexAppServerClient
    private let discoveryLimit: Int
    private let minimumBackoff: Duration
    private let maximumBackoff: Duration
    private var enabled: Bool
    private var client: CodexAppServerClient?
    private var reducer = CodexAppServerReducer()
    private var subscribed: Set<String> = []
    private var state = Diagnostics()

    public init(
        enabled: Bool = true,
        socketPath: String = CodexAppServerClient.defaultSocketPath,
        discoveryLimit: Int = 50,
        minimumBackoff: Duration = .seconds(2),
        maximumBackoff: Duration = .seconds(30),
        makeClient: @escaping @Sendable (String) -> CodexAppServerClient = { CodexAppServerClient(socketPath: $0) }
    ) {
        self.enabled = enabled
        self.socketPath = socketPath
        self.discoveryLimit = discoveryLimit
        self.minimumBackoff = minimumBackoff
        self.maximumBackoff = maximumBackoff
        self.makeClient = makeClient
        state.enabled = enabled
    }

    public func diagnostics() -> Diagnostics { state }

    /// Turning the monitor off closes the connection; the run loop then idles
    /// until it is turned on again.
    public func setEnabled(_ on: Bool) {
        enabled = on
        state.enabled = on
        if !on { disconnect(reason: nil) }
    }

    /// Runs until cancelled. Safe to call once per monitor.
    public func run(store: SessionStore) async {
        var backoff = minimumBackoff
        while !Task.isCancelled {
            guard enabled else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            guard FileManager.default.fileExists(atPath: socketPath) else {
                // No daemon: not a failure, just nothing to read yet.
                state.connected = false
                state.lastError = nil
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, maximumBackoff)
                continue
            }
            do {
                try await session(store: store)
                backoff = minimumBackoff
            } catch {
                disconnect(reason: "\(error)")
                await store.recordSourceSignal(agent: .codex, source: .appserver,
                                               health: Self.health(for: error), at: Date())
            }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, maximumBackoff)
        }
        disconnect(reason: nil)
    }

    // MARK: - One connection

    private func session(store: SessionStore) async throws {
        let client = makeClient(socketPath)
        try client.connect()
        self.client = client
        reducer = CodexAppServerReducer()
        subscribed = []
        // `experimentalApi` is required for `thread/resume.excludeTurns`, the
        // documented way to subscribe without replaying a thread's history; the
        // monitor still only calls the four read-side methods listed above.
        let hello = try await client.request("initialize", params: [
            "clientInfo": ["name": "vibebuddy", "version": Self.version],
            "capabilities": ["experimentalApi": true],
        ])
        client.notify("initialized")
        state.connected = true
        state.lastError = nil
        state.serverUserAgent = hello["userAgent"] as? String
        state.serverRequestsSeen = []
        await store.recordSourceSignal(agent: .codex, source: .appserver, health: .healthy, at: Date())

        try await discover(client: client, store: store)

        for await raw in client.messages {
            guard enabled, !Task.isCancelled else { break }
            guard let message = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            if let method = CodexAppServerReducer.serverRequestMethod(message) {
                state.serverRequestsSeen.append(method)
                if state.serverRequestsSeen.count > 20 { state.serverRequestsSeen.removeFirst() }
                continue
            }
            let now = Date()
            let events = reducer.handle(message, receivedAt: now)
            if !events.isEmpty {
                state.lastEventAt = now
                for event in events { await store.ingest(event) }
            }
            // A thread we did not subscribe to has started or come alive:
            // subscribe so its turn/item stream reaches us too.
            if let threadID = Self.threadID(of: message),
               reducer.threads[threadID]?.loaded == true, !subscribed.contains(threadID) {
                await subscribe(threadID, client: client, store: store)
            }
        }
        // The stream ends only when the socket closed under us.
        guard enabled, !Task.isCancelled else { return }
        throw CodexAppServerClient.ClientError.closed
    }

    /// Page the daemon's stored threads once and subscribe to every loaded one.
    private func discover(client: CodexAppServerClient, store: SessionStore) async throws {
        var cursor: String?
        var pages = 0
        repeat {
            var params: [String: Any] = ["limit": discoveryLimit]
            if let cursor { params["cursor"] = cursor }
            let page = try await client.request("thread/list", params: params)
            let threads = page["data"] as? [[String: Any]] ?? []
            let now = Date()
            for thread in threads {
                let events = reducer.seed(thread: thread, receivedAt: now)
                if !events.isEmpty {
                    state.lastEventAt = now
                    for event in events { await store.ingest(event) }
                }
                if let id = thread["id"] as? String, reducer.threads[id]?.loaded == true {
                    await subscribe(id, client: client, store: store)
                }
            }
            cursor = page["nextCursor"] as? String
            pages += 1
        } while cursor != nil && pages < 4
    }

    /// `thread/resume` with `excludeTurns` is how a second client subscribes to
    /// a loaded thread's notifications without replaying its history. The
    /// resume result carries the thread's current facts, so it is seeded again.
    private func subscribe(_ threadID: String, client: CodexAppServerClient, store: SessionStore) async {
        do {
            let result = try await client.request("thread/resume",
                                                  params: ["threadId": threadID, "excludeTurns": true])
            subscribed.insert(threadID)
            state.subscribedThreads = subscribed.count
            if let thread = result["thread"] as? [String: Any] {
                let now = Date()
                for event in reducer.seed(thread: thread, receivedAt: now) {
                    state.lastEventAt = now
                    await store.ingest(event)
                }
            }
        } catch {
            // A thread that unloaded between listing and resuming, or a
            // protocol mismatch on this one call: keep the connection, note it.
            state.lastError = "thread/resume \(threadID.suffix(8)): \(error)"
        }
    }

    private func disconnect(reason: String?) {
        client?.close()
        client = nil
        subscribed = []
        state.connected = false
        state.subscribedThreads = 0
        if let reason { state.lastError = reason }
    }

    private static func health(for error: Error) -> ObservationHealth {
        switch error as? CodexAppServerClient.ClientError {
        case .rpc?, .malformed?: return .unknownVersion
        default: return .sourceUnreadable
        }
    }

    private static func threadID(of message: [String: Any]) -> String? {
        let params = message["params"] as? [String: Any]
        if let id = params?["threadId"] as? String { return id }
        return (params?["thread"] as? [String: Any])?["id"] as? String
    }

    private static let version: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }()
}
