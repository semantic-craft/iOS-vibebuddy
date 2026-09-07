import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("Cursor browser cookie import")
struct CursorBrowserCookieImporterTests {
    @Test("resolver in manual mode requires a pasted cookie")
    func manualRequiresPaste() {
        #expect(throws: AccountUsageError.notLoggedIn) {
            try CursorCookieResolver.resolve(
                mode: .manual,
                manualCookie: nil,
                importer: FailingImporter()
            )
        }
        let header = try! CursorCookieResolver.resolve(
            mode: .manual,
            manualCookie: "WorkosCursorSessionToken=abc",
            importer: FailingImporter()
        )
        #expect(header == "WorkosCursorSessionToken=abc")
    }

    @Test("browserAuto uses import then falls back to manual paste")
    func browserAutoFallback() throws {
        var persisted: String?
        let imported = try CursorCookieResolver.resolve(
            mode: .browserAuto,
            manualCookie: nil,
            importer: ScriptedImporter(header: "WorkosCursorSessionToken=from-browser"),
            persistImportedCookie: { persisted = $0 }
        )
        #expect(imported == "WorkosCursorSessionToken=from-browser")
        #expect(persisted == imported)

        let fallback = try CursorCookieResolver.resolve(
            mode: .browserAuto,
            manualCookie: "WorkosCursorSessionToken=pasted",
            importer: FailingImporter()
        )
        #expect(fallback == "WorkosCursorSessionToken=pasted")

        #expect(throws: AccountUsageError.notLoggedIn) {
            try CursorCookieResolver.resolve(
                mode: .browserAuto,
                manualCookie: nil,
                importer: FailingImporter()
            )
        }
    }

    @Test("provider fetch in browserAuto does not crash when import fails")
    func providerSurvivesImportFailure() async {
        let provider = CursorUsageProvider(
            cookie: nil,
            cookieMode: { .browserAuto },
            cookieImporter: FailingImporter(),
            transport: MissingTransport()
        )
        await #expect(throws: AccountUsageError.notLoggedIn) {
            try await provider.fetch()
        }
    }

    private struct ScriptedImporter: CursorBrowserCookieImporting {
        let header: String
        func importSessionCookieHeader(allowKeychainPrompt: Bool) throws -> String { header }
    }

    private struct FailingImporter: CursorBrowserCookieImporting {
        func importSessionCookieHeader(allowKeychainPrompt: Bool) throws -> String {
            throw AccountUsageError.notLoggedIn
        }
    }

    private struct MissingTransport: CursorUsageTransport {
        func cursorData(for request: URLRequest) async throws -> (Data, URLResponse) {
            Issue.record("network should not run without a cookie")
            throw URLError(.badURL)
        }
    }
}
