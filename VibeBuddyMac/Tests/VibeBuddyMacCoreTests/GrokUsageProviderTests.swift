import Darwin
import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("Grok usage adapter")
struct GrokUsageProviderTests {
    private let now = Date(timeIntervalSince1970: 1_788_314_400)

    @Test("a valid period-only bill preserves the plan without inventing usage")
    func periodOnlyBill() throws {
        let body = Data(#"{"result":{"subscription_tier":"SuperGrok Heavy","config":{"currentPeriod":{"start":"2026-09-06T11:36:49Z","end":"2026-09-13T11:36:49Z"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0}}}}"#.utf8)
        let snapshot = try GrokUsageResponseDecoder.decode(billingResponse: body, fetchedAt: now)
        #expect(snapshot.primary == nil)
        #expect(snapshot.planType == "SuperGrok Heavy")
        #expect(AccountUsageState.available(snapshot, nextRefreshAt: nil).unavailableReason == .unknown)
    }

    @Test("period-only billing recovers usage or preserves unknown without swallowing cancellation",
          arguments: ["success", "offline", "cancelled", "task-cancelled"])
    func recoverPeriodOnlyBill(outcome: String) async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reply = #"{"jsonrpc":"2.0","id":2,"result":{"subscription_tier":"SuperGrok Heavy","config":{"currentPeriod":{"start":"2026-09-06T11:36:49Z","end":"2026-09-13T11:36:49Z"}}}}"#
        let executable = try Self.writeFakeAgent(in: directory, transcript: directory.appendingPathComponent("requests"), reply: reply)
        let auth = directory.appendingPathComponent("auth.json")
        try Data(#"{"https://auth.x.ai::openid":{"key":"test-token","expires_at":"2099-01-01T00:00:00Z"}}"#.utf8).write(to: auth)
        let transport = ScriptedProxyTransport { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            if outcome == "offline" { throw URLError(.notConnectedToInternet) }
            if outcome == "cancelled" { throw URLError(.cancelled) }
            if outcome == "task-cancelled" { throw CancellationError() }
            // Declared GrokCreditsConfig fields: percent 42.5, active weekly period.
            let hex = "0a190d00002a4242120802120608d1a0f5d4061a0608d1959ad506"
            let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            return (Data(bytes), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["grpc-status": "0"])!)
        }
        let provider = GrokUsageProvider(executableURL: executable,
            logURL: directory.appendingPathComponent("absent"), authFileURL: auth,
            proxyTransport: transport, now: { Date(timeIntervalSince1970: 1_788_750_000) })
        if outcome == "task-cancelled" {
            await #expect(throws: CancellationError.self) { try await provider.fetch() }
            return
        }
        if outcome == "cancelled" {
            await #expect(throws: URLError(.cancelled)) { try await provider.fetch() }
            return
        }
        let snapshot = try await provider.fetch()
        #expect(snapshot.primary?.usedPercent == (outcome == "success" ? 43 : nil))
        #expect(snapshot.planType == "SuperGrok Heavy")
        #expect(Self.matches(snapshot.periodEnd, "2026-09-13T11:36:49Z"))
    }

    @Test("a log fallback keeps its sampled time and remains cached")
    func logRemainsCached() throws {
        let snapshot = try GrokUsageResponseDecoder.decode(unifiedLogLine: Self.logLine())
        let state = AccountUsageState.available(snapshot, nextRefreshAt: nil)
        #expect(state.isStale)
        #expect(state.unavailableReason == .cachedData)
        #expect(abs(snapshot.fetchedAt.timeIntervalSince1970 - 1_788_395_550.702) < 0.001)
    }

    // MARK: - Decoding

    @Test("credits config maps the weekly window, reset time, and tier")
    func creditsConfigDecoding() throws {
        let snapshot = try GrokUsageResponseDecoder.decode(
            billingResponse: Self.billingResponse(),
            fetchedAt: now
        )

        #expect(snapshot.provider == .grok)
        #expect(snapshot.planType == "SuperGrok Heavy")
        #expect(snapshot.primary?.usedPercent == 36)
        #expect(snapshot.primary?.windowDurationMinutes == 10_080)
        #expect(Self.matches(snapshot.primary?.resetsAt, "2026-09-06T11:36:49Z"))
        // A zero on-demand cap means the account has no on-demand allowance.
        #expect(snapshot.secondary == nil)
        #expect(snapshot.lifetimeTokens == nil)
        #expect(snapshot.fetchedAt == now)
    }

    @Test("an on-demand cap becomes the secondary window")
    func onDemandWindow() throws {
        let response = Self.billingResponse(
            onDemandCap: #"{"val":5000}"#,
            onDemandUsed: #"{"val":1250}"#
        )
        let snapshot = try GrokUsageResponseDecoder.decode(billingResponse: response, fetchedAt: now)

        #expect(snapshot.secondary?.kind == .secondary)
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.secondary?.windowDurationMinutes == 10_080)
        #expect(Self.matches(snapshot.secondary?.resetsAt, "2026-09-06T11:36:49Z"))
    }

    @Test("a percentage outside zero through one hundred is rejected")
    func percentageBounds() {
        let response = Self.billingResponse(creditUsagePercent: "101.0")
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try GrokUsageResponseDecoder.decode(billingResponse: response, fetchedAt: now)
        }
    }

    @Test("a payload with no usable usage is unavailable instead of zero")
    func missingUsage() {
        let response = Data(#"{"jsonrpc":"2.0","id":2,"result":{"config":{"onDemandCap":{"val":100}}}}"#.utf8)
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try GrokUsageResponseDecoder.decode(billingResponse: response, fetchedAt: now)
        }
    }

    @Test("RPC errors map onto the shared unavailable reasons")
    func errorMapping() {
        let unauthenticated = Data(#"""
        {"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required","data":"Billing data requires auth with grok.com. Run `grok login` to authenticate."}}
        """#.utf8)
        #expect(throws: AccountUsageError.notLoggedIn) {
            try GrokUsageResponseDecoder.decode(billingResponse: unauthenticated, fetchedAt: now)
        }

        let unknownMethod = Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
        #expect(throws: AccountUsageError.providerUnavailable) {
            try GrokUsageResponseDecoder.decode(billingResponse: unknownMethod, fetchedAt: now)
        }

        let rateLimited = Data(#"""
        {"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Billing service error: HTTP 429 too many requests"}}
        """#.utf8)
        #expect(throws: AccountUsageError.rateLimited) {
            try GrokUsageResponseDecoder.decode(billingResponse: rateLimited, fetchedAt: now)
        }
    }

    @Test("the unified log record carries its own fetch time")
    func logRecordDecoding() throws {
        let snapshot = try GrokUsageResponseDecoder.decode(unifiedLogLine: Self.logLine())

        #expect(snapshot.provider == .grok)
        #expect(snapshot.planType == "SuperGrok Heavy")
        #expect(snapshot.primary?.usedPercent == 36)
        #expect(Self.matches(snapshot.fetchedAt, "2026-09-03T00:32:30Z"))
    }

    @Test("an unrelated log record is not a usage reading")
    func unrelatedLogRecord() {
        let line = Data(#"{"ts":"2026-09-03T00:32:30.702Z","src":"shell","lvl":"info","msg":"session: started"}"#.utf8)
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try GrokUsageResponseDecoder.decode(unifiedLogLine: line)
        }
    }

    @Test("the newest credits record in a log tail wins, and stale records are ignored")
    func logTailScan() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("unified.jsonl")
        let contents = [
            #"{"ts":"2026-09-02T00:00:00.000Z","src":"shell","lvl":"info","msg":"hook: ran"}"#,
            String(decoding: Self.logLine(timestamp: "2026-09-02T23:00:00.000Z", percent: "12.0"), as: UTF8.self),
            #"{"ts":"2026-09-03T00:10:00.000Z","src":"shell","lvl":"info","msg":"turn: completed"}"#,
            String(decoding: Self.logLine(), as: UTF8.self),
            #"{"ts":"2026-09-03T00:40:00.000Z","src":"shell","lvl":"info","msg":"turn: completed"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: logURL)

        let readAt = Self.timestamp("2026-09-03T01:00:00Z")!
        let snapshot = GrokUsageResponseDecoder.decodeNewestLogRecord(in: logURL, now: readAt)
        #expect(snapshot?.primary?.usedPercent == 36)

        let muchLater = readAt.addingTimeInterval(GrokUsageResponseDecoder.logFallbackMaxAge + 60)
        #expect(GrokUsageResponseDecoder.decodeNewestLogRecord(in: logURL, now: muchLater) == nil)
        #expect(
            GrokUsageResponseDecoder.decodeNewestLogRecord(
                in: directory.appendingPathComponent("absent.jsonl"),
                now: readAt
            ) == nil
        )
    }

    @Test("timestamps parse at second, millisecond, and microsecond precision")
    func timestampPrecision() {
        // The proxy emits microseconds and a `+00:00` offset; the log emits
        // milliseconds and `Z`. Reset times are shown to the minute, so landing
        // within a second of the stamp is the requirement.
        #expect(Self.matches(
            GrokUsageResponseDecoder.parseTimestamp("2026-09-06T11:36:49.308758+00:00"),
            "2026-09-06T11:36:49Z"
        ))
        #expect(Self.matches(
            GrokUsageResponseDecoder.parseTimestamp("2026-09-03T00:32:30.702Z"),
            "2026-09-03T00:32:30Z"
        ))
        #expect(
            GrokUsageResponseDecoder.parseTimestamp("2026-09-06T11:36:49Z")
                == Self.timestamp("2026-09-06T11:36:49Z")
        )
        #expect(GrokUsageResponseDecoder.parseTimestamp("not a date") == nil)
        #expect(GrokUsageResponseDecoder.parseTimestamp(nil) == nil)
    }

    // MARK: - Provider

    @Test("the provider speaks the handshake and maps the billing reply")
    func providerHandshake() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("stdin.txt")
        let agent = try Self.writeFakeAgent(
            in: directory,
            transcript: transcript,
            reply: String(decoding: Self.billingResponse(), as: UTF8.self)
        )

        let snapshot = try await GrokUsageProvider(
            executableURL: agent,
            arguments: [],
            timeout: 5,
            logURL: directory.appendingPathComponent("absent.jsonl")
        ).fetch()

        #expect(snapshot.provider == .grok)
        #expect(snapshot.primary?.usedPercent == 36)

        let sent = try String(contentsOf: transcript, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(sent.count == 2)
        let initialize = try #require(sent.first.flatMap(Self.json))
        #expect(initialize["method"] as? String == "initialize")
        #expect((initialize["params"] as? [String: Any])?["protocolVersion"] as? Int == 1)
        let billing = try #require(sent.last.flatMap(Self.json))
        // The unescaped extension name is what the agent matches on.
        #expect(billing["method"] as? String == "_x.ai/billing")
        #expect(sent.last?.contains("_x.ai/billing") == true)
    }

    @Test("an unreachable agent falls back to the last logged billing record")
    func logFallback() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("unified.jsonl")
        let recent = Self.logLine(
            timestamp: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600)),
            percent: "72.0"
        )
        try (recent + Data("\n".utf8)).write(to: logURL)

        let snapshot = try await GrokUsageProvider(
            executableURL: directory.appendingPathComponent("no-such-binary"),
            arguments: [],
            timeout: 5,
            logURL: logURL
        ).fetch()
        #expect(snapshot.primary?.usedPercent == 72)

        // A signed-out account is reported, never masked by a stale reading.
        #expect(!GrokUsageProvider.allowsLogFallback(after: AccountUsageError.notLoggedIn))
        #expect(GrokUsageProvider.allowsLogFallback(after: AccountUsageError.providerUnavailable))
        #expect(!GrokUsageProvider.allowsLogFallback(after: CancellationError()))
    }

    @Test("a signed-out agent is reported instead of falling back")
    func signedOutIsReported() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("unified.jsonl")
        try (Self.logLine(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            percent: "72.0"
        ) + Data("\n".utf8)).write(to: logURL)
        let agent = try Self.writeFakeAgent(
            in: directory,
            transcript: directory.appendingPathComponent("stdin.txt"),
            reply: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required","data":"Run `grok login` to authenticate."}}"#
        )

        await #expect(throws: AccountUsageError.notLoggedIn) {
            try await GrokUsageProvider(
                executableURL: agent, arguments: [], timeout: 5, logURL: logURL
            ).fetch()
        }
    }

    @Test("a stalled agent times out and its child process is reaped")
    func timeoutReapsChild() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("agent.pid")
        let provider = GrokUsageProvider(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "trap '' TERM; echo $$ > \"$1\"; exec sleep 5",
                "vibebuddy-test", pidFile.path,
            ],
            timeout: 0.2,
            logURL: directory.appendingPathComponent("absent.jsonl"), proxyEnabled: false
        )

        let started = ContinuousClock.now
        await #expect(throws: AccountUsageError.timedOut) { try await provider.fetch() }
        #expect(ContinuousClock.now - started < .seconds(2))

        let pid = try #require(Int32(
            try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("cancellation stops the fetch and the child")
    func cancellation() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("agent.pid")
        let provider = GrokUsageProvider(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "echo $$ > \"$1\"; exec sleep 10",
                "vibebuddy-test", pidFile.path,
            ],
            timeout: 10,
            logURL: directory.appendingPathComponent("absent.jsonl")
        )

        let fetch = Task { try await provider.fetch() }
        var pid: Int32?
        for _ in 0..<200 where pid == nil {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if pid == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(pid != nil)
        fetch.cancel()
        await #expect(throws: (any Error).self) { try await fetch.value }

        if let pid {
            for _ in 0..<200 where Darwin.kill(pid, 0) == 0 {
                try? await Task.sleep(for: .milliseconds(10))
            }
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    /// Live diagnostic: only runs with `VIBEBUDDY_GROK_LIVE=1` and a signed-in
    /// CLI. It prints the percentage and tier only.
    @Test("live Grok CLI reports a quota window")
    func liveFetch() async throws {
        guard ProcessInfo.processInfo.environment["VIBEBUDDY_GROK_LIVE"] == "1" else {
            print("VIBEBUDDY_GROK_LIVE not set — skipping live Grok usage test")
            return
        }
        let snapshot = try await GrokUsageProvider().fetch()
        print("""
        live grok usage: plan=\(snapshot.planType ?? "nil") \
        primary=\(snapshot.primary.map { "\($0.usedPercent)%" } ?? "nil") \
        windowMinutes=\(snapshot.primary?.windowDurationMinutes.map(String.init) ?? "nil") \
        secondary=\(snapshot.secondary.map { "\($0.usedPercent)%" } ?? "nil") \
        resetsIn=\(snapshot.primary?.resetsAt.map { Int($0.timeIntervalSinceNow / 3600) } ?? -1)h
        """)
        #expect(snapshot.provider == .grok)
        #expect(snapshot.primary != nil)
    }

    
    @Test("CLI proxy credits JSON maps onto the same Grok snapshot shape")
    func proxyCreditsDecode() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let body = Data("""
        {
          "config": {
            "creditUsagePercent": 12.5,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-06T00:00:00Z",
              "end": "2026-08-13T00:00:00Z"
            },
            "billingPeriodEnd": "2026-08-13T00:00:00Z",
            "onDemandCap": { "val": 1000 },
            "onDemandUsed": { "val": 250 }
          },
          "subscriptionTier": "SuperGrok Heavy"
        }
        """.utf8)
        let snapshot = try GrokUsageResponseDecoder.decode(proxyCreditsResponse: body, fetchedAt: now)
        #expect(snapshot.provider == .grok)
        #expect(snapshot.planType == "SuperGrok Heavy")
        #expect(snapshot.primary?.usedPercent == 13) // 12.5 rounded
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.primary?.usedPercent != 0 || snapshot.primary != nil)
    }

    @Test("extra usage never becomes the included Grok allowance")
    func proxyOnDemandOnlyPrimary() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let body = Data("""
        {
          "config": {
            "onDemandCap": { "val": 1000.0 },
            "onDemandUsed": { "val": 250.0 },
            "billingPeriodStart": "2026-08-06T00:00:00Z",
            "billingPeriodEnd": "2026-08-13T00:00:00Z"
          }
        }
        """.utf8)
        let snapshot = try GrokUsageResponseDecoder.decode(proxyCreditsResponse: body, fetchedAt: now)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.fetchedAt == now)
    }

    @Test("period-only proxy answers stay unavailable rather than inventing 0%")
    func proxyPeriodOnlyRejected() {
        let body = Data("""
        {
          "config": {
            "currentPeriod": { "end": "2026-08-13T00:00:00Z" },
            "billingPeriodEnd": "2026-08-14T00:00:00Z"
          },
          "subscriptionTier": "SuperGrok Heavy"
        }
        """.utf8)
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try GrokUsageResponseDecoder.decode(proxyCreditsResponse: body, fetchedAt: Date())
        }
    }

    @Test("auth.json reader prefers the OIDC scope key and respects expiry")
    func authTokenReader() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        let future = "2099-01-01T00:00:00Z"
        let past = "2000-01-01T00:00:00Z"
        try Data("""
        {
          "https://auth.x.ai::openid": {
            "key": "oidc-token",
            "expires_at": "\(future)"
          },
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-token",
            "expires_at": "\(future)"
          }
        }
        """.utf8).write(to: auth)
        #expect(GrokCLIAuthToken.loadAccessToken(from: auth) == "oidc-token")

        try Data("""
        {
          "https://auth.x.ai::openid": {
            "key": "expired",
            "expires_at": "\(past)"
          }
        }
        """.utf8).write(to: auth)
        #expect(GrokCLIAuthToken.loadAccessToken(from: auth) == nil)
    }

    @Test("unreachable ACP falls through log miss into the billing proxy")
    func proxyFallbackAfterPrimaryMiss() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        try Data("""
        {
          "https://auth.x.ai::openid": {
            "key": "token-123",
            "expires_at": "2099-01-01T00:00:00Z"
          }
        }
        """.utf8).write(to: auth)
        let endpoint = URL(string: "https://grok.test/v1/billing?format=credits")!
        let transport = ScriptedProxyTransport(handler: { request in
            #expect(request.url == endpoint)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
            #expect(request.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")
            let body = Data("""
            {"config":{"creditUsagePercent":44.0,"currentPeriod":{"start":"2026-08-06T00:00:00Z","end":"2026-08-13T00:00:00Z"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0}},"subscriptionTier":"SuperGrok"}
            """.utf8)
            let response = HTTPURLResponse(
                url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        })
        let snapshot = try await GrokUsageProvider(
            executableURL: URL(fileURLWithPath: "/bin/false"),
            arguments: [],
            timeout: 1,
            logURL: directory.appendingPathComponent("absent.jsonl"),
            authFileURL: auth,
            proxyEndpoint: endpoint,
            proxyTransport: transport
        ).fetch()
        #expect(snapshot.provider == .grok)
        #expect(snapshot.primary?.usedPercent == 44)
        #expect(snapshot.planType == "SuperGrok")
    }

    @Test("proxy failure leaves the original primary error in place")
    func proxyFailureDoesNotMaskPrimary() async {
        let directory = try! Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        try! Data("""
        {"https://auth.x.ai::openid":{"key":"token-123","expires_at":"2099-01-01T00:00:00Z"}}
        """.utf8).write(to: auth)
        let endpoint = URL(string: "https://grok.test/v1/billing?format=credits")!
        let transport = ScriptedProxyTransport(handler: { _ in
            throw URLError(.notConnectedToInternet)
        })
        await #expect(throws: AccountUsageError.providerUnavailable) {
            try await GrokUsageProvider(
                executableURL: URL(fileURLWithPath: "/bin/false"),
                arguments: [],
                timeout: 1,
                logURL: directory.appendingPathComponent("absent.jsonl"),
                authFileURL: auth,
                proxyEndpoint: endpoint,
                proxyTransport: transport
            ).fetch()
        }
    }


    private struct ScriptedProxyTransport: GrokCreditsProxyTransport {
        let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
        func proxyData(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await handler(request)
        }
    }

// MARK: - Fixtures

    private static func billingResponse(
        creditUsagePercent: String = "36.0",
        onDemandCap: String = #"{"val":0}"#,
        onDemandUsed: String = #"{"val":0}"#
    ) -> Data {
        Data(#"""
        {"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":\#(creditUsagePercent),\#
        "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-30T11:36:49.308758+00:00",\#
        "end":"2026-09-06T11:36:49.308758+00:00"},"onDemandCap":\#(onDemandCap),\#
        "onDemandUsed":\#(onDemandUsed),"prepaidBalance":{"val":0},"isUnifiedBillingUser":true,\#
        "billingPeriodStart":"2026-08-30T11:36:49.308758+00:00",\#
        "billingPeriodEnd":"2026-09-06T11:36:49.308758+00:00"},"subscription_tier":"SuperGrok Heavy"}}
        """#.utf8)
    }

    private static func logLine(
        timestamp: String = "2026-09-03T00:32:30.702Z",
        percent: String = "36.0"
    ) -> Data {
        Data(#"""
        {"ts":"\#(timestamp)","src":"shell","pid":10083,"ver":"1.0.13","lvl":"info",\#
        "msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":\#(percent),\#
        "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-30T11:36:49.308758+00:00",\#
        "end":"2026-09-06T11:36:49.308758+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},\#
        "prepaidBalance":{"val":0},"isUnifiedBillingUser":true,"historyLen":0},"onDemandEnabled":null,\#
        "subscriptionTier":"SuperGrok Heavy"}}
        """#.utf8)
    }

    /// A stand-in for `grok agent --no-leader stdio`: it records the handshake
    /// it is given and answers the second request with a canned reply.
    private static func writeFakeAgent(
        in directory: URL,
        transcript: URL,
        reply: String
    ) throws -> URL {
        let script = """
        #!/bin/sh
        read -r line || exit 1
        printf '%s\\n' "$line" >> "\(transcript.path)"
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        printf '%s\\n' '{"jsonrpc":"2.0","method":"_x.ai/mcp/servers_updated","params":{}}'
        read -r line || exit 1
        printf '%s\\n' "$line" >> "\(transcript.path)"
        printf '%s\\n' '\(reply)'
        exec sleep 5
        """
        let url = directory.appendingPathComponent("fake-grok")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-grok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Reset times drive a minute-resolution label, so sub-second differences
    /// between the wire precisions do not matter.
    private static func matches(_ date: Date?, _ iso: String) -> Bool {
        guard let date, let base = timestamp(iso) else { return false }
        return abs(date.timeIntervalSince(base)) < 1
    }

    private static func timestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func json(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
}
