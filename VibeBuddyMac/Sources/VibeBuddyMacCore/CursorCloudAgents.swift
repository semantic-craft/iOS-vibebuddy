import Foundation
import Security
import VibeBuddyKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport seam for `https://api.cursor.com`, shaped like
/// `CursorUsageTransport` so tests never reach the network.
public protocol CursorCloudTransport: Sendable {
    func cursorCloudData(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CursorCloudTransport {
    public func cursorCloudData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// Keychain slot for the Cursor Cloud Agents API key.
///
/// Three Cursor credentials exist and none of them substitutes for another: the
/// app's `WorkosCursorSessionToken` cookie (quota, `CursorSessionCookieStore`),
/// the `cursor-agent` CLI's own login (kept by the CLI in the login keychain,
/// never read here), and this key — minted at cursor.com/dashboard/api and the
/// only credential the Cloud Agents API accepts. So it gets its own account,
/// beside the two cookie slots rather than inside them.
public enum CursorCloudAPIKeyStore {
    public static let keychainAccount = "cursorCloudAPIKey"

    public static func load(read: (String) -> String? = { KeychainStore.get($0) }) -> String? {
        read(keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
    }

    @discardableResult
    public static func save(
        _ value: String?,
        write: (String?, String) -> OSStatus = { KeychainStore.set($0, for: $1) }
    ) -> OSStatus {
        write(value?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty, keychainAccount)
    }

    /// Whether a key is stored, **without decrypting it**. Settings uses this to
    /// print "saved" without ever raising a Keychain authorization prompt — and
    /// without the key passing through the UI layer at all.
    public static func isConfigured(exists: (String) -> Bool = { KeychainStore.exists($0) }) -> Bool {
        exists(keychainAccount)
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

/// Cursor's agent-level state. Three values, and only three
/// (`cursor.com/docs/cloud-agent/api/endpoints`, checked 2026-09-12).
public enum CursorCloudAgentStatus: String, Codable, Sendable {
    /// A turn is running, waiting on background work, or about to start.
    case active = "ACTIVE"
    /// The last turn finished and follow-ups are accepted.
    case idle = "IDLE"
    /// Archived or expired. Terminal.
    case archived = "ARCHIVED"
}

/// One cloud agent as the API reports it.
public struct CursorCloudAgent: Equatable, Sendable {
    public let id: String
    public let name: String?
    public let status: CursorCloudAgentStatus
    /// Where it runs: `cloud` for Cursor's own VMs, `pool` / `machine` for a
    /// self-hosted worker.
    public let environment: String?
    /// Cursor's web page for this agent — the only place the conversation can
    /// actually be opened, since it runs nowhere on this Mac.
    public let url: String?
    /// The repository it works on (`github.com/org/repo`). A cloud agent has no
    /// local folder, so this is what stands in for a project. Only the per-agent
    /// endpoint carries it, so it arrives a beat after the row does.
    public let repository: String?
    public let latestRunID: String?
    public let updatedAt: Date?

    public init(id: String, name: String? = nil, status: CursorCloudAgentStatus,
                environment: String? = nil, url: String? = nil,
                repository: String? = nil,
                latestRunID: String? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.environment = environment
        self.url = url
        self.repository = repository
        self.latestRunID = latestRunID
        self.updatedAt = updatedAt
    }
}

/// One run — a single prompt and everything it produced.
public struct CursorCloudRun: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case creating = "CREATING"
        case running = "RUNNING"
        case finished = "FINISHED"
        case error = "ERROR"
        case cancelled = "CANCELLED"
        case expired = "EXPIRED"

        /// Whether Cursor still considers this run live. Only one run can be
        /// active per agent, which is what makes a follow-up land or bounce.
        public var isLive: Bool { self == .creating || self == .running }
    }

    public let id: String
    public let agentID: String
    public let status: Status
    /// The final assistant reply. Present on a terminal run only.
    public let result: String?
    public let branch: String?
    public let pullRequestURL: String?
    public let updatedAt: Date?

    public init(id: String, agentID: String, status: Status, result: String? = nil,
                branch: String? = nil, pullRequestURL: String? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.agentID = agentID
        self.status = status
        self.result = result
        self.branch = branch
        self.pullRequestURL = pullRequestURL
        self.updatedAt = updatedAt
    }
}

/// Why a Cloud Agents call did not produce an answer.
///
/// Deliberately closed and deliberately textual only in `message`, which carries
/// Cursor's own `code` — never a URL, a header or any part of the key. A leaked
/// credential in a log line is exactly what the separate Keychain slot is for.
public enum CursorCloudError: Error, Equatable, Sendable {
    /// No key in the Keychain. The user has not set this up.
    case missingKey
    /// 401 / 403 — the key is wrong, revoked, or lacks the scope.
    case unauthorized
    /// 409 `agent_busy`: a run is already `CREATING` or `RUNNING`. Cursor allows
    /// exactly one live run per agent, so a follow-up must wait for it.
    case busy
    case notFound
    case rateLimited
    /// Anything else Cursor answered, reduced to its status and `code`.
    case service(status: Int, code: String?)
    case transport
    case undecodable
}

/// The Cursor Cloud Agents API, v1.
///
/// v1 is the current surface and is in public beta; v0 is legacy. The two are
/// shaped differently and the difference matters here: v0 had a flat
/// `POST /v0/agents/{id}/followup`, while v1 splits the work into a **durable
/// agent plus one run per prompt**, so a follow-up *is* `POST /v1/agents/{id}/runs`.
/// The agent id is the `bc-…` id vibebuddy already reads out of Cursor's own
/// composer database, so no second identity has to be kept.
public struct CursorCloudAgentClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.cursor.com")!

    private let baseURL: URL
    private let apiKey: @Sendable () -> String?
    private let transport: CursorCloudTransport
    private let timeout: TimeInterval

    public init(baseURL: URL = defaultBaseURL,
                apiKey: @escaping @Sendable () -> String? = { CursorCloudAPIKeyStore.load() },
                transport: CursorCloudTransport = URLSession.shared,
                timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
        self.timeout = timeout
    }

    public var isConfigured: Bool { apiKey() != nil }

    /// Every agent on the account, following `nextCursor` to the end.
    ///
    /// `includeArchived=false`: an archived agent is one the person filed away,
    /// and ADR-0016 already keeps Cursor's archived conversations out of the
    /// buckets. `pages` bounds an account with a very long history — a dashboard
    /// is work in progress, not an archive.
    public func agents(limit: Int = 100, pages: Int = 5) async throws -> [CursorCloudAgent] {
        var collected: [CursorCloudAgent] = []
        var cursor: String?
        for _ in 0..<max(1, pages) {
            var items = [URLQueryItem(name: "limit", value: String(limit)),
                         URLQueryItem(name: "includeArchived", value: "false")]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: AgentListDTO = try await send("/v1/agents", method: "GET", query: items)
            collected += page.items.compactMap(Self.agent(from:))
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return collected
    }

    public func run(agentID: String, runID: String) async throws -> CursorCloudRun {
        let dto: RunDTO = try await send("/v1/agents/\(encoded(agentID))/runs/\(encoded(runID))",
                                        method: "GET")
        guard let run = Self.run(from: dto) else { throw CursorCloudError.undecodable }
        return run
    }

    /// Start a new run on an existing agent — v1's follow-up.
    ///
    /// Throws `.busy` on Cursor's `409 agent_busy`, which is what an agent with a
    /// live run answers. Callers refuse *before* sending too; this is the race
    /// that beats the check.
    public func startRun(agentID: String, text: String) async throws -> CursorCloudRun {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw CursorCloudError.undecodable }
        let body = try? JSONSerialization.data(withJSONObject: ["prompt": ["text": prompt]])
        let dto: CreateRunDTO = try await send("/v1/agents/\(encoded(agentID))/runs",
                                               method: "POST", body: body)
        guard let run = Self.run(from: dto.run) else { throw CursorCloudError.undecodable }
        return run
    }

    /// The per-agent record, which is the only place `repos` appears — the list
    /// endpoint carries identity fields only.
    public func agent(id: String) async throws -> CursorCloudAgent {
        let dto: AgentDTO = try await send("/v1/agents/\(encoded(id))", method: "GET")
        guard let agent = Self.agent(from: dto) else { throw CursorCloudError.undecodable }
        return agent
    }

    /// Every run on one agent, newest first — v1's stand-in for v0's
    /// `/conversation`, which v1 does not have. One run is one turn, and its
    /// `result` is what that turn finally said.
    public func runs(agentID: String, limit: Int = 20) async throws -> [CursorCloudRun] {
        let page: RunListDTO = try await send("/v1/agents/\(encoded(agentID))/runs", method: "GET",
                                              query: [URLQueryItem(name: "limit", value: String(limit))])
        return page.items.compactMap(Self.run(from:))
    }

    /// Cancel a live run. Cursor answers `409 run_not_cancellable` for a run
    /// that already reached a terminal state or never started, which is a
    /// refusal rather than a failure — the turn the person was looking at is
    /// already over.
    public func cancelRun(agentID: String, runID: String) async throws {
        let _: CancelDTO = try await send(
            "/v1/agents/\(encoded(agentID))/runs/\(encoded(runID))/cancel", method: "POST")
    }

    /// Start the next run and say, in the person's terms, what happened.
    ///
    /// `busy` is the one worth its own sentence: the phone was looking at an
    /// idle agent, a run started in between, and Cursor allows only one at a
    /// time. Nothing was queued and nothing will be — Cursor has no waiting
    /// room for a follow-up, so saying "try again when it finishes" is the whole
    /// truth. Every other failure names what the person can fix, and none of
    /// them repeats the key.
    public func continueAgent(id: String, text: String) async -> SessionActionDelivery {
        do {
            _ = try await startRun(agentID: id, text: text)
            return .accepted
        } catch CursorCloudError.busy {
            return .failed(String(localized: "This cloud agent started another run. Try again once it finishes."))
        } catch CursorCloudError.missingKey {
            return .failed(String(localized: "Add a Cursor API key on your Mac to reach cloud agents from here."))
        } catch CursorCloudError.unauthorized {
            return .failed(String(localized: "Cursor refused the API key. Check it in Settings on your Mac."))
        } catch CursorCloudError.notFound {
            return .failed(String(localized: "Cursor no longer has this cloud agent."))
        } catch CursorCloudError.rateLimited {
            return .failed(String(localized: "Cursor is rate-limiting this Mac. Try again in a moment."))
        } catch {
            // The request may well have reached Cursor. `unknown` is the answer
            // that tells the person to look rather than to send again.
            return .unknown
        }
    }

    /// The recent dialogue for a cloud agent, as `/recent-output` wants it.
    ///
    /// v1 has no `/conversation` endpoint — v0 did, and the agent/run split
    /// replaced it. One run is one turn, so the runs list *is* the conversation:
    /// each terminal run's `result` is what that turn finally said. A run still
    /// going has no result yet and says so rather than showing nothing.
    ///
    /// Read-only and bounded, like every other recent-output source: fetching it
    /// acknowledges no completion and moves no state.
    public func recentOutput(agentID: String, limit: Int = 8,
                             perEntryLimit: Int = 2000) async -> RecentOutput {
        let runs: [CursorCloudRun]
        do {
            runs = try await self.runs(agentID: agentID, limit: limit)
        } catch CursorCloudError.missingKey {
            // No key is not an unreadable source; it is no source at all.
            return .unavailable(sessionId: agentID, reason: .noSource, source: .cloud)
        } catch {
            return .unavailable(sessionId: agentID, reason: .unreadable, source: .cloud)
        }
        var entries: [RecentOutputEntry] = []
        var truncated = false
        // Oldest first, the way a conversation reads.
        for run in runs.reversed() {
            guard let text = run.result ?? Self.pendingText(for: run.status) else { continue }
            if text.count > perEntryLimit { truncated = true }
            entries.append(RecentOutputEntry(role: "assistant", text: String(text.prefix(perEntryLimit))))
        }
        return RecentOutput(sessionId: agentID, source: .cloud,
                            updatedAt: runs.compactMap(\.updatedAt).max(),
                            truncated: truncated, entries: entries)
    }

    /// What to show for a run with no `result`. A live run genuinely has no text
    /// yet; a terminal one that produced none says how it ended instead of
    /// vanishing from the conversation.
    static func pendingText(for status: CursorCloudRun.Status) -> String? {
        switch status {
        case .creating, .running: return nil
        case .finished: return nil
        case .error: return "This run ended with an error."
        case .cancelled: return "This run was cancelled."
        case .expired: return "This run expired."
        }
    }

    /// Cancel the live run and say which of the three things happened, in the
    /// same vocabulary a Codex interrupt answers in — the phone already knows
    /// how to read `sent` / `notSent` / `unconfirmed`.
    ///
    /// `run_not_cancellable` is `notSent`, not a failure: the turn the person
    /// was looking at has already ended, and saying so is the honest answer.
    public func cancel(agentID: String, runID: String) async -> CodexAppServerMonitor.InterruptOutcome {
        do {
            try await cancelRun(agentID: agentID, runID: runID)
            return .sent
        } catch CursorCloudError.service(_, let code) where code == "run_not_cancellable" {
            return .notSent(String(localized: "This run has already finished."))
        } catch CursorCloudError.missingKey {
            return .notSent(String(localized: "Add a Cursor API key on your Mac to reach cloud agents from here."))
        } catch CursorCloudError.unauthorized {
            return .notSent(String(localized: "Cursor refused the API key. Check it in Settings on your Mac."))
        } catch CursorCloudError.notFound {
            return .notSent(String(localized: "Cursor no longer has this run."))
        } catch {
            // It may have reached Cursor. Never retried, never followed by
            // another method: the same rule the Codex interrupt follows.
            return .unconfirmed
        }
    }

    // MARK: - Wire

    private func encoded(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
            ?? component
    }

    private func send<T: Decodable>(_ path: String, method: String,
                                    query: [URLQueryItem] = [],
                                    body: Data? = nil) async throws -> T {
        guard let key = apiKey() else { throw CursorCloudError.missingKey }
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else {
            throw CursorCloudError.transport
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CursorCloudError.transport }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("VibeBuddy", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.cursorCloudData(for: request)
        } catch {
            // The URLError's own description can name the request. Nothing from
            // it is carried forward — the key travels in a header on that
            // request, and no diagnostic is worth the risk of echoing it.
            throw CursorCloudError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw CursorCloudError.transport }
        switch http.statusCode {
        case 200..<300:
            guard let decoded = try? Self.decoder.decode(T.self, from: data) else {
                throw CursorCloudError.undecodable
            }
            return decoded
        case 401, 403:
            throw CursorCloudError.unauthorized
        case 404:
            throw CursorCloudError.notFound
        case 409:
            // `agent_busy` is the one 409 with its own meaning for us; any other
            // conflict stays a plain service error so it is not mis-explained.
            throw Self.errorCode(data) == "agent_busy"
                ? CursorCloudError.busy
                : CursorCloudError.service(status: 409, code: Self.errorCode(data))
        case 429:
            throw CursorCloudError.rateLimited
        default:
            throw CursorCloudError.service(status: http.statusCode, code: Self.errorCode(data))
        }
    }

    /// Cursor's error body is `{"code":…,"message":…}`. Only `code` is kept:
    /// `message` is free text from the service and has no place in a log.
    static func errorCode(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty else { return nil }
        return code
    }

    static let decoder = JSONDecoder()

    struct AgentListDTO: Decodable {
        var items: [AgentDTO]
        var nextCursor: String?
    }

    struct AgentDTO: Decodable {
        var id: String?
        var name: String?
        var status: String?
        var env: EnvDTO?
        var url: String?
        var updatedAt: String?
        var latestRunId: String?
        var repos: [RepoDTO]?
    }

    struct EnvDTO: Decodable { var type: String? }

    struct RepoDTO: Decodable {
        var url: String?
        var startingRef: String?
        var prUrl: String?
    }

    struct CreateRunDTO: Decodable { var run: RunDTO }

    struct RunListDTO: Decodable {
        var items: [RunDTO]
        var nextCursor: String?
    }

    struct CancelDTO: Decodable { var id: String? }

    struct RunDTO: Decodable {
        var id: String?
        var agentId: String?
        var status: String?
        var result: String?
        var updatedAt: String?
        var git: GitDTO?
    }

    struct GitDTO: Decodable {
        var branches: [BranchDTO]?
        struct BranchDTO: Decodable {
            var repoUrl: String?
            var branch: String?
            var prUrl: String?
        }
    }

    /// An agent whose `status` this build does not recognize is dropped rather
    /// than guessed at: a status vibebuddy cannot read must not become a state
    /// in the three buckets. Same rule the hook parser follows.
    static func agent(from dto: AgentDTO) -> CursorCloudAgent? {
        guard let id = dto.id, !id.isEmpty,
              let raw = dto.status, let status = CursorCloudAgentStatus(rawValue: raw) else { return nil }
        return CursorCloudAgent(id: id, name: dto.name?.nilWhenBlank, status: status,
                                environment: dto.env?.type, url: dto.url?.nilWhenBlank,
                                repository: dto.repos?.compactMap { $0.url?.nilWhenBlank }.first,
                                latestRunID: dto.latestRunId?.nilWhenBlank,
                                updatedAt: dto.updatedAt.flatMap(Self.date(from:)))
    }

    static func run(from dto: RunDTO) -> CursorCloudRun? {
        guard let id = dto.id, !id.isEmpty, let agentID = dto.agentId, !agentID.isEmpty,
              let raw = dto.status, let status = CursorCloudRun.Status(rawValue: raw) else { return nil }
        let branch = dto.git?.branches?.compactMap { $0.branch?.nilWhenBlank }.first
        let pr = dto.git?.branches?.compactMap { $0.prUrl?.nilWhenBlank }.first
        return CursorCloudRun(id: id, agentID: agentID, status: status,
                              result: dto.result?.nilWhenBlank, branch: branch,
                              pullRequestURL: pr, updatedAt: dto.updatedAt.flatMap(Self.date(from:)))
    }

    /// ISO 8601, with and without fractional seconds — Cursor sends both.
    static func date(from value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

private extension String {
    var nilWhenBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Jump into a Cursor cloud agent.
///
/// It runs on Cursor's machines, so there is no window to raise and no terminal
/// to focus — only the page Cursor hosts for it, which the API hands back as the
/// agent's `url`. This is the Codex Desktop shape (ADR-0011), and it follows
/// `CodexDesktopJumper`'s rule: the value arrives from a network response, so it
/// is checked against a closed allowlist rather than escaped. Nothing that is not
/// recognisably a Cursor agent page is handed to a browser.
public enum CursorCloudJumper {
    /// `https://cursor.com/...` and nothing else: no other scheme, no other
    /// host, no userinfo. A redirected `url` field must not become an open-redirect
    /// through the user's default browser.
    static func validated(_ page: String) -> URL? {
        guard let url = URL(string: page.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              host == "cursor.com" || host.hasSuffix(".cursor.com") else { return nil }
        return url
    }

    public static func jump(page: String,
                            open: @Sendable (URL) async -> Bool = { await openInBrowser($0) }) async -> JumpOutcome {
        guard let url = validated(page) else { return .unsupported }
        return await open(url) ? .focused : .unsupported
    }

    public static func openInBrowser(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url.absoluteString]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let once = Once(continuation)
            process.terminationHandler = { once.finish($0.terminationStatus == 0) }
            do { try process.run() } catch { once.finish(false); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if process.isRunning { process.terminate(); once.finish(false) }
            }
        }
    }

    /// Resumes a continuation exactly once, whichever of the termination handler
    /// and the timeout fires first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ ok: Bool) {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(returning: ok)
            continuation = nil
        }
    }
}
