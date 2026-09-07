import Foundation
import Testing
import Hummingbird
import HummingbirdTesting
import NIOCore
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Cursor quota relay")
struct CursorQuotaRelayTests {
    @Test("Cursor pools survive Mac snapshot, phone projection, and Watch serialization")
    func poolsAndSourceTransitions() async throws {
        let now = Date()
        let json = #"{"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"autoPercentUsed":24,"apiPercentUsed":61}}}"#
        let sample = try CursorUsageSummaryDecoder.decode(Data(json.utf8), fetchedAt: now)
        let store = SessionStore(sourceID: "quota-test")
        let available = AccountUsageState.available(sample, nextRefreshAt: nil)
        var cached = available
        cached.isStale = true
        for state in [available, cached, .disabled,
                      .unavailable(.notLoggedIn, lastAttemptAt: now, nextRefreshAt: nil), available] {
            let quotas = ProviderQuota.all(from: [.cursor: state])
            await store.setProviderQuota(quotas)
            let wire = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(await store.snapshot(now: now)))
            #expect(wire.providerQuota?.map(\.provider) == AccountUsageProvider.allCases)
            let phone = WatchDashboardProjection.make(snapshot: wire, quotas: wire.providerQuota ?? [], relay: .live, now: now)
            let watch = try JSONDecoder().decode(WatchDashboardState.self, from: JSONEncoder().encode(phone))
            #expect(watch.quotas == quotas)
            let cursor = try #require(watch.quotas.first { $0.provider == .cursor })
            if state.snapshot != nil {
                #expect(cursor.isCached == state.isStale)
                #expect(cursor.otherWindows?.allSatisfy { $0.isCached == state.isStale } == true)
                #expect(cursor.weeklyRemainingPercent == nil)
                #expect(cursor.otherWindows?.map(\.label) == ["Cursor Models", "Other Models"])
                #expect(cursor.otherWindows?.map(\.remainingPercent) == [76, 39])
                #expect(cursor.otherWindows?.allSatisfy { $0.durationMinutes == 43200 && $0.observedAt == now } == true)
                for window in cursor.otherWindows ?? [] {
                    let reset = try #require(window.resetsAt)
                    #expect(window.status(now: reset) == .awaitingReset)
                    #expect(window.currentRemainingPercent(now: reset) == nil)
                }
            } else {
                #expect(cursor.unavailableReason != nil)
                #expect(cursor.displayWindow().remainingPercent == nil)
            }
        }
    }

    @Test("Internal complete snapshots need peer projection for strict pre-Cursor clients")
    func strictOldClientRejectsCursor() throws {
        enum OldProvider: String, Decodable { case codex, claude, grok }
        struct OldQuota: Decodable { var provider: OldProvider }
        let rows = try JSONEncoder().encode(ProviderQuota.all(from: [:]))
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode([OldQuota].self, from: rows)
        }
    }

    @Test("HTTP and WebSocket independently preserve old peers and publish Cursor to capable peers")
    func negotiatedTransport() async throws {
        let store = SessionStore(sourceID: "isolated-transport")
        let quota = ProviderQuota.all(from: [:])
        await store.setProviderQuota(quota)
        let server = VibeBuddyServer(store: store, token: "isolated-test", host: "127.0.0.1", port: 0,
                                     backgroundSessions: { [] })
        try await server.buildApplication().test(.live) { client in
            let port = try #require(client.port)
            let current = "?quotaProviders=" + AccountUsageProvider.allCases.map(\.rawValue).joined(separator: ",")
            for query in ["", current] {
                let expected: [AccountUsageProvider] = query.isEmpty ? [.codex, .claude, .grok] : AccountUsageProvider.allCases
                try await client.execute(uri: "/snapshot" + query, method: .get,
                                         headers: [.authorization: "Bearer isolated-test"]) { response in
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(buffer: response.body))
                    #expect(snapshot.providerQuota?.map(\.provider) == expected)
                    if query.isEmpty {
                        enum OldProvider: String, Decodable { case codex, claude, grok }
                        struct Row: Decodable { let provider: OldProvider }
                        struct OldSnapshot: Decodable { let providerQuota: [Row] }
                        let old = try JSONDecoder().decode(OldSnapshot.self, from: Data(buffer: response.body))
                        #expect(old.providerQuota.count == 3)
                    }
                }
                var request = URLRequest(url: URL(string: "ws://localhost:\(port)/ws" + query)!)
                request.setValue("Bearer isolated-test", forHTTPHeaderField: "Authorization")
                let socket = URLSession.shared.webSocketTask(with: request)
                socket.resume()
                defer { socket.cancel(with: .goingAway, reason: nil) }
                func receive() async throws -> Snapshot {
                    let message = try await socket.receive()
                    guard case let .string(text) = message,
                          case let .snapshot(snapshot) = try JSONDecoder().decode(ServerEvent.self, from: Data(text.utf8)) else {
                        throw NSError(domain: "CursorQuotaRelayTests", code: 1)
                    }
                    return snapshot
                }
                #expect(try await receive().providerQuota?.map(\.provider) == expected)
                var changed = quota
                changed[0].unavailableReason = "Transport update " + query
                await store.setProviderQuota(changed)
                let update = try await receive()
                #expect(update.providerQuota?.map(\.provider) == expected)
                #expect(update.providerQuota?.first?.unavailableReason == changed[0].unavailableReason)
            }
            #expect(await store.snapshot(now: Date()).providerQuota?.map(\.provider) == AccountUsageProvider.allCases)
        }
    }

    // Opt-in local acceptance uses the configured CLI login through the production
    // adapter; only normalized quota is printed, never credentials or raw response.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_CURSOR_RELAY_LIVE"] == "1"))
    func configuredCLISource() async throws {
        let mode = CursorCookieSourceSettings.mode(defaults: UserDefaults(suiteName: "com.vibebuddy.mac")!)
        #expect(mode == .cursorCLI)
        let sample = try await CursorUsageProvider(cookieMode: { mode }).fetch()
        let quota = ProviderQuota(.available(sample, nextRefreshAt: nil), provider: .cursor)
        #expect(quota.otherWindows?.isEmpty == false)
        let store = SessionStore(sourceID: "isolated-live-quota")
        await store.setProviderQuota(ProviderQuota.all(from: [.cursor: .available(sample, nextRefreshAt: nil)]))
        let server = VibeBuddyServer(store: store, token: "isolated-live", host: "127.0.0.1", port: 0,
                                     backgroundSessions: { [] })
        try await server.buildApplication().test(.live) { client in
            try await client.execute(uri: "/snapshot?quotaProviders=codex,claude,grok,cursor", method: .get,
                                     headers: [.authorization: "Bearer isolated-live"]) { response in
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(buffer: response.body))
                let phone = WatchDashboardProjection.make(snapshot: snapshot, quotas: snapshot.providerQuota ?? [], relay: .live, now: Date())
                let watch = try JSONDecoder().decode(WatchDashboardState.self, from: JSONEncoder().encode(phone))
                #expect(watch.quotas.first { $0.provider == .cursor } == quota)
            }
        }
        print("CURSOR_RELAY_NORMALIZED " + String(decoding: try JSONEncoder().encode(quota), as: UTF8.self))
    }
}
