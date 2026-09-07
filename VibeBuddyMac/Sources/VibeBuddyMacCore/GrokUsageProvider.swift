import Darwin
import Foundation

/// Pure mapping from Grok Build's billing payloads onto `AccountUsageSnapshot`.
///
/// Two payloads carry the same `config` object: the `_x.ai/billing` ACP
/// response (`{"result":{"config":{…},"subscription_tier":…}}`), and the
/// `billing: fetched credits config` record the CLI writes to
/// `<grok home>/logs/unified.jsonl` (`ctx.config` + `ctx.subscriptionTier`).
public enum GrokUsageResponseDecoder {
    /// The `billing: fetched credits config` record is written on every billing
    /// fetch; anything older than this is treated as no data rather than as a
    /// current reading.
    public static let logFallbackMaxAge: TimeInterval = 24 * 60 * 60

    static let creditsLogMessage = "billing: fetched credits config"

    /// Decodes one JSON-RPC response line for `_x.ai/billing`.
    public static func decode(billingResponse: Data, fetchedAt: Date) throws -> AccountUsageSnapshot {
        let envelope: BillingEnvelopeDTO
        do {
            envelope = try JSONDecoder().decode(BillingEnvelopeDTO.self, from: billingResponse)
        } catch {
            throw AccountUsageError.incompatibleFormat
        }
        if let error = envelope.error { throw classify(error) }
        guard let result = envelope.result else { throw AccountUsageError.incompatibleFormat }
        return try snapshot(
            config: result.config,
            tier: result.subscriptionTier ?? result.subscriptionTierSnakeCase,
            fetchedAt: fetchedAt
        )
    }

    /// Decodes one `~/.grok/logs/unified.jsonl` record. The record's own
    /// timestamp becomes `fetchedAt`, so a cached reading never claims to be
    /// newer than it is.
    public static func decode(unifiedLogLine: Data) throws -> AccountUsageSnapshot {
        let record: UnifiedLogRecordDTO
        do {
            record = try JSONDecoder().decode(UnifiedLogRecordDTO.self, from: unifiedLogLine)
        } catch {
            throw AccountUsageError.incompatibleFormat
        }
        guard record.msg == creditsLogMessage,
              let context = record.ctx,
              let timestamp = parseTimestamp(record.ts) else {
            throw AccountUsageError.incompatibleFormat
        }
        var reading = try snapshot(
            config: context.config,
            tier: context.subscriptionTier,
            fetchedAt: timestamp
        )
        reading.isCached = true
        return reading
    }

    /// Returns the newest credits record in the tail of a unified log, or nil
    /// when the file holds no usable reading.
    public static func decodeNewestLogRecord(
        in logURL: URL,
        now: Date,
        maxAge: TimeInterval = logFallbackMaxAge,
        tailBytes: Int = 512 * 1_024
    ) -> AccountUsageSnapshot? {
        guard let tail = readTail(of: logURL, bytes: tailBytes) else { return nil }
        let marker = Data(creditsLogMessage.utf8)
        for line in tail.split(separator: 0x0A).reversed() {
            let line = Data(line)
            guard line.range(of: marker) != nil else { continue }
            guard let snapshot = try? decode(unifiedLogLine: line) else { continue }
            guard now.timeIntervalSince(snapshot.fetchedAt) <= maxAge else { return nil }
            return snapshot
        }
        return nil
    }

    /// Decodes `GET …/v1/billing?format=credits` (CodexBar CLI-proxy shape).
    /// Included usage and extra usage remain separate. A complete billing
    /// period without included usage is a valid unknown reading.
    public static func decode(proxyCreditsResponse: Data, fetchedAt: Date) throws -> AccountUsageSnapshot {
        let envelope: ProxyCreditsEnvelopeDTO
        do {
            envelope = try JSONDecoder().decode(ProxyCreditsEnvelopeDTO.self, from: proxyCreditsResponse)
        } catch {
            throw AccountUsageError.incompatibleFormat
        }
        return try snapshot(config: envelope.config,
                            tier: envelope.config?.subscriptionTier ?? envelope.subscriptionTier,
                            fetchedAt: fetchedAt)
    }

    private static func snapshot(
        config: BillingConfigDTO?,
        tier: String?,
        fetchedAt: Date
    ) throws -> AccountUsageSnapshot {
        guard let config else { throw AccountUsageError.incompatibleFormat }
        let start = parseTimestamp(config.periodStart)
        let resetsAt = parseTimestamp(config.periodEnd)
        let durationMinutes = duration(from: start, to: resetsAt)

        let creditPercent = config.creditPercent
        if let creditPercent {
            guard creditPercent.isFinite, (0...100).contains(creditPercent) else {
                throw AccountUsageError.incompatibleFormat
            }
        } else {
            guard let start, let resetsAt, start < resetsAt else {
                throw AccountUsageError.incompatibleFormat
            }
        }

        var onDemand: AccountUsageWindow?
        if let cap = config.onDemandCap?.val, cap > 0, let used = config.onDemandUsedValue {
            let percent = min(100, max(0, used / cap * 100))
            guard percent.isFinite else { throw AccountUsageError.incompatibleFormat }
            onDemand = AccountUsageWindow(
                kind: .secondary,
                usedPercent: Int(percent.rounded()),
                windowDurationMinutes: durationMinutes,
                resetsAt: resetsAt
            )
        }

        return AccountUsageSnapshot(
            provider: .grok,
            planType: tier.flatMap { $0.isEmpty ? nil : $0 },
            primary: creditPercent.map { AccountUsageWindow(
                kind: .primary,
                usedPercent: Int($0.rounded()),
                windowDurationMinutes: durationMinutes,
                resetsAt: resetsAt
            ) },
            secondary: onDemand,
            lifetimeTokens: nil,
            latestDailyTokens: nil,
            fetchedAt: fetchedAt,
            periodStart: start,
            periodEnd: resetsAt
        )
    }

    private static func duration(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end, end > start else { return nil }
        return Int((end.timeIntervalSince(start) / 60).rounded())
    }

    private static func classify(_ error: RPCErrorDTO) -> AccountUsageError {
        let text = ([error.message, error.data?.text].compactMap { $0 }).joined(separator: " ")
        let value = text.lowercased()
        if value.contains("method not found") { return .providerUnavailable }
        if value.contains("auth") || value.contains("grok login") { return .notLoggedIn }
        return AccountUsageError.classify(message: text)
    }

    /// The proxy emits microsecond precision, which `ISO8601DateFormatter`
    /// rejects outright, so a fraction-free retry is the last step.
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        guard let dot = raw.firstIndex(of: ".") else { return nil }
        let afterDot = raw.index(after: dot)
        let suffix = raw[afterDot...].firstIndex(where: { !$0.isNumber }) ?? raw.endIndex
        return formatter.date(from: String(raw[..<dot] + raw[suffix...]))
    }

    private static func readTail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.readToEnd()
    }
}

// MARK: - Wire shapes

private struct RPCErrorDTO: Decodable {
    var message: String
    var data: LenientTextDTO?
}

/// ACP puts a human-readable hint in `error.data`, which is a string for the
/// billing handler but is free-form JSON in general.
private struct LenientTextDTO: Decodable {
    var text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        text = try? container.decode(String.self)
    }
}

private struct BillingEnvelopeDTO: Decodable {
    var result: BillingResultDTO?
    var error: RPCErrorDTO?
}

private struct ProxyCreditsEnvelopeDTO: Decodable {
    var config: BillingConfigDTO?
    var subscriptionTier: String?
}

private struct BillingResultDTO: Decodable {
    var config: BillingConfigDTO?
    /// The handler answers `subscription_tier`; `/v1/settings` and some builds
    /// spell it camelCase, and both are cheap to accept.
    var subscriptionTier: String?
    var subscriptionTierSnakeCase: String?

    enum CodingKeys: String, CodingKey {
        case config
        case subscriptionTier
        case subscriptionTierSnakeCase = "subscription_tier"
    }
}

private struct CentDTO: Decodable {
    var val: Double

    enum CodingKeys: String, CodingKey { case val }

    /// proto3 JSON omits zero-valued scalars, so `$0` arrives as `{}`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        val = try container.decodeIfPresent(Double.self, forKey: .val) ?? 0
    }
}

private struct UsagePeriodDTO: Decodable {
    var start: String?
    var end: String?
}

private struct BillingConfigDTO: Decodable {
    var creditUsagePercent: Double?
    var currentPeriod: UsagePeriodDTO?
    /// Documented as deprecated but still emitted, and the only usage figures an
    /// account without a credits percentage carries.
    var monthlyLimit: CentDTO?
    var used: CentDTO?
    var onDemandCap: CentDTO?
    var onDemandUsed: CentDTO?
    var billingPeriodStart: String?
    var billingPeriodEnd: String?
    /// Present on some CLI-proxy credits payloads (CodexBar).
    var subscriptionTier: String?

    /// Percent of the included allowance. The credits config reports it
    /// directly; the deprecated fields only carry an amount and a limit.
    var creditPercent: Double? {
        if let percent = creditUsagePercent { return percent }
        guard let limit = monthlyLimit?.val, limit > 0, let spent = used?.val else { return nil }
        return min(100, max(0, spent / limit * 100))
    }

    var onDemandUsedValue: Double? { onDemandUsed?.val }

    var periodStart: String? { currentPeriod?.start ?? billingPeriodStart }

    var periodEnd: String? { currentPeriod?.end ?? billingPeriodEnd }
}

private struct UnifiedLogContextDTO: Decodable {
    var config: BillingConfigDTO?
    var subscriptionTier: String?
}

private struct UnifiedLogRecordDTO: Decodable {
    var ts: String?
    var msg: String?
    var ctx: UnifiedLogContextDTO?
}

// MARK: - Provider

/// Reads Grok Build's weekly credit quota through the CLI's own ACP server.
/// When the agent cannot be spawned or reached, the last billing record the
/// CLI wrote to its unified log stands in. If that still yields no usable
/// percent, the CodexBar-documented CLI billing proxy is tried with the local
/// `~/.grok/auth.json` bearer — same Grok row, never a second provider.
public final class GrokUsageProvider: AccountUsageProviding, Sendable {
    private let executableURL: URL?
    private let arguments: [String]
    private let timeout: TimeInterval
    private let logURL: URL
    private let authFileURL: URL
    private let proxyEndpoint: URL
    private let proxyTransport: GrokCreditsProxyTransport
    private let proxyEnabled: Bool
    private let now: @Sendable () -> Date

    public init(
        executableURL: URL? = nil,
        arguments: [String] = ["agent", "--no-leader", "stdio"],
        timeout: TimeInterval = 10,
        logURL: URL? = nil,
        authFileURL: URL? = nil,
        proxyEndpoint: URL = GrokCreditsProxyClient.defaultEndpoint,
        proxyTransport: GrokCreditsProxyTransport = GrokCreditsProxyClient.session,
        proxyEnabled: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.executableURL = executableURL ?? Self.resolveGrokExecutable()
        self.arguments = arguments
        self.timeout = timeout
        self.logURL = logURL ?? Self.defaultLogURL()
        self.authFileURL = authFileURL ?? GrokHome.url.appendingPathComponent("auth.json")
        self.proxyEndpoint = proxyEndpoint
        self.proxyTransport = proxyTransport
        self.proxyEnabled = proxyEnabled
        self.now = now
    }

    public func fetch() async throws -> AccountUsageSnapshot {
        try Task.checkCancellation()
        let token = proxyEnabled ? GrokCLIAuthToken.loadAccessToken(from: authFileURL) : nil
        let client = GrokACPClient()
        let executableURL = executableURL
        let arguments = arguments
        let timeout = timeout
        let logURL = logURL
        return try await withTaskCancellationHandler {
            do {
                guard let executableURL else { throw AccountUsageError.providerUnavailable }
                let response = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result {
                            try client.exchange(
                                executableURL: executableURL,
                                arguments: arguments,
                                requests: [GrokACPClient.initializeRequest, GrokACPClient.billingRequest],
                                responseID: GrokACPClient.billingRequest.id,
                                timeout: timeout
                            )
                        })
                    }
                }
                try Task.checkCancellation()
                let snapshot = try GrokUsageResponseDecoder.decode(billingResponse: response, fetchedAt: now())
                // ACP owns authentication. Never merge if it refreshed/switched the
                // captured credential during this request.
                guard proxyEnabled, token == GrokCLIAuthToken.loadAccessToken(from: authFileURL) else { return snapshot }
                return try await recoverUnknown(snapshot, token: token)
            } catch {
                try Task.checkCancellation()
                guard Self.allowsLogFallback(after: error) else { throw error }
                if let snapshot = GrokUsageResponseDecoder.decodeNewestLogRecord(
                    in: logURL,
                    now: Date()
                ) {
                    return snapshot
                }
                if proxyEnabled, let snapshot = try await Self.fetchProxyFallback(
                    token: token,
                    endpoint: proxyEndpoint,
                    transport: proxyTransport,
                    now: now()
                ) {
                    return try await recoverUnknown(snapshot, token: token)
                }
                throw error
            }
        } onCancel: {
            client.cancel()
        }
    }

    private func recoverUnknown(_ snapshot: AccountUsageSnapshot, token: String?) async throws -> AccountUsageSnapshot {
        guard snapshot.primary == nil, let token else { return snapshot }
        do {
            let reading = try await GrokWebCredits.fetch(token: token, transport: proxyTransport, now: now())
            guard let start = snapshot.periodStart, let end = snapshot.periodEnd,
                  abs(start.timeIntervalSince(reading.start)) < 1,
                  abs(end.timeIntervalSince(reading.end)) < 1 else { return snapshot }
            var recovered = snapshot
            recovered.primary = AccountUsageWindow(kind: .primary,
                usedPercent: Int(reading.percent.rounded()),
                windowDurationMinutes: Int((end.timeIntervalSince(start) / 60).rounded()), resetsAt: end)
            return recovered
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw error }
            return snapshot
        }
    }

    /// Best-effort proxy: never upgrades a hard auth/format failure from ACP, and
    /// never invents a reading when the bearer is missing.
    static func fetchProxyFallback(
        token: String?,
        endpoint: URL,
        transport: GrokCreditsProxyTransport,
        now: Date = Date()
    ) async throws -> AccountUsageSnapshot? {
        guard let token else {
            return nil
        }
        do {
            let data = try await GrokCreditsProxyClient.fetch(
                accessToken: token,
                endpoint: endpoint,
                transport: transport
            )
            try Task.checkCancellation()
            return try GrokUsageResponseDecoder.decode(proxyCreditsResponse: data, fetchedAt: now)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            return nil
        }
    }

    /// A refused or unreachable agent is exactly what the log record covers. A
    /// signed-out account or an unreadable payload is reported as such instead,
    /// because a stale reading would hide it.
    static func allowsLogFallback(after error: any Error) -> Bool {
        switch error {
        case is CancellationError: return false
        case let url as URLError where url.code == .cancelled: return false
        case let usage as AccountUsageError:
            switch usage {
            case .providerUnavailable, .timedOut, .offline, .unknown: return true
            case .notLoggedIn, .rateLimited, .incompatibleFormat: return false
            }
        default: return true
        }
    }

    public static func resolveGrokExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        grokHome: URL = GrokHome.url,
        fileManager: FileManager = .default
    ) -> URL? {
        let fixed = [
            grokHome.appendingPathComponent("bin/grok").path,
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
            "/usr/bin/grok",
        ]
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/grok" }
        return (fixed + fromPath)
            .first(where: fileManager.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    public static func defaultLogURL(grokHome: URL = GrokHome.url) -> URL {
        grokHome.appendingPathComponent("logs/unified.jsonl")
    }
}
