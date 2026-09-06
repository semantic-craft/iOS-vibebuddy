import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("Cursor usage adapter")
struct CursorUsageProviderTests {
    @Test("plan-only usage-summary maps to primary used % and reset")
    func planOnlyFixture() throws {
        let data = try Self.fixture("usage-summary-plan-only")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try CursorUsageSummaryDecoder.decode(data, fetchedAt: now)
        #expect(snapshot.provider == .cursor)
        #expect(snapshot.planType == "pro")
        #expect(snapshot.primary?.usedPercent == 40)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.primary?.windowDurationMinutes == 31 * 24 * 60) // Aug has 31 days
    }

    @Test("plan + on-demand maps secondary only when on-demand has a limit")
    func planAndOnDemandFixture() throws {
        let data = try Self.fixture("usage-summary-plan-ondemand")
        let snapshot = try CursorUsageSummaryDecoder.decode(data, fetchedAt: Date())
        #expect(snapshot.primary?.usedPercent == 75)
        #expect(snapshot.secondary?.usedPercent == 25)
    }

    @Test("auth-shaped payload without plan figures is incompatible, not 0%")
    func authFailureShape() throws {
        let data = try Self.fixture("usage-summary-auth-failure")
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try CursorUsageSummaryDecoder.decode(data, fetchedAt: Date())
        }
    }

    @Test("HTTP 401 becomes notLoggedIn")
    func httpUnauthorized() async throws {
        let endpoint = URL(string: "https://cursor.test/api/usage-summary")!
        let transport = ScriptedCursorTransport { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=redacted")
            let response = HTTPURLResponse(
                url: endpoint, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        let provider = CursorUsageProvider(
            cookie: "WorkosCursorSessionToken=redacted",
            endpoint: endpoint,
            transport: transport
        )
        await #expect(throws: AccountUsageError.notLoggedIn) {
            try await provider.fetch()
        }
    }

    @Test("successful cookie fetch decodes the usage-summary body")
    func successfulFetch() async throws {
        let endpoint = URL(string: "https://cursor.test/api/usage-summary")!
        let body = try Self.fixture("usage-summary-plan-only")
        let transport = ScriptedCursorTransport { _ in
            let response = HTTPURLResponse(
                url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
        let snapshot = try await CursorUsageProvider(
            cookie: "WorkosCursorSessionToken=redacted",
            endpoint: endpoint,
            transport: transport
        ).fetch()
        #expect(snapshot.provider == .cursor)
        #expect(snapshot.primary?.usedPercent == 40)
    }

    private struct ScriptedCursorTransport: CursorUsageTransport {
        let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
        func cursorData(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await handler(request)
        }
    }

    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/cursor"
        ))
        return try Data(contentsOf: url)
    }
}
