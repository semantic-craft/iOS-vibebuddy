import Foundation
import Security
import SweetCookieKit
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
                loadManual: { nil },
                importer: FailingImporter()
            )
        }
        let header = try! CursorCookieResolver.resolve(
            mode: .manual,
            manualCookie: "WorkosCursorSessionToken=abc",
            loadManual: { nil },
            importer: FailingImporter()
        )
        #expect(header == "WorkosCursorSessionToken=abc")
    }

    @Test("browserAuto uses import then falls back to manual paste")
    func browserAutoFallback() throws {
        var persisted: [String] = []
        let imported = try CursorCookieResolver.resolve(
            mode: .browserAuto,
            manualCookie: nil,
            loadManual: { nil },
            importer: ScriptedImporter(header: "WorkosCursorSessionToken=from-browser"),
            persistImportedCookie: { persisted.append($0) }
        )
        #expect(imported == "WorkosCursorSessionToken=from-browser")
        #expect(persisted == [imported])

        let fallback = try CursorCookieResolver.resolve(
            mode: .browserAuto,
            manualCookie: "WorkosCursorSessionToken=pasted",
            loadManual: { nil },
            importer: FailingImporter(),
            persistImportedCookie: { _ in Issue.record("must not persist on import failure") }
        )
        #expect(fallback == "WorkosCursorSessionToken=pasted")

        #expect(throws: AccountUsageError.notLoggedIn) {
            try CursorCookieResolver.resolve(
                mode: .browserAuto,
                manualCookie: nil,
                loadManual: { nil },
                importer: FailingImporter()
            )
        }
    }

    @Test("dual-slot resolve keeps manual paste across auto-import cycles")
    func dualSlotManualSurvivesAutoImport() throws {
        let slots = InMemoryCookieSlots([
            CursorSessionCookieStore.manualKeychainAccount: "WorkosCursorSessionToken=manual-fallback",
        ])

        // First auto import lands only in the imported slot.
        let first = try CursorCookieResolver.resolve(
            mode: .browserAuto,
            manualCookie: nil,
            loadManual: { CursorSessionCookieStore.loadManual(read: slots.read) },
            importer: ScriptedImporter(header: "WorkosCursorSessionToken=auto-1"),
            persistImportedCookie: {
                _ = CursorSessionCookieStore.saveImportedIfChanged($0, read: slots.read, write: slots.write)
            }
        )
        #expect(first == "WorkosCursorSessionToken=auto-1")
        #expect(slots.values[CursorSessionCookieStore.manualKeychainAccount] == "WorkosCursorSessionToken=manual-fallback")
        #expect(slots.values[CursorSessionCookieStore.importedKeychainAccount] == "WorkosCursorSessionToken=auto-1")

        // Identical refresh must not rewrite the imported slot.
        let writesBefore = slots.writeCount
        _ = try CursorCookieResolver.resolve(
            mode: .browserAuto,
            manualCookie: nil,
            loadManual: { CursorSessionCookieStore.loadManual(read: slots.read) },
            importer: ScriptedImporter(header: "WorkosCursorSessionToken=auto-1"),
            persistImportedCookie: {
                _ = CursorSessionCookieStore.saveImportedIfChanged($0, read: slots.read, write: slots.write)
            }
        )
        #expect(slots.writeCount == writesBefore)

        // Changed import updates imported only; manual still intact for fallback.
        let second = try CursorCookieResolver.resolve(
            mode: .browserAuto,
            manualCookie: nil,
            loadManual: { CursorSessionCookieStore.loadManual(read: slots.read) },
            importer: ScriptedImporter(header: "WorkosCursorSessionToken=auto-2"),
            persistImportedCookie: {
                _ = CursorSessionCookieStore.saveImportedIfChanged($0, read: slots.read, write: slots.write)
            }
        )
        #expect(second == "WorkosCursorSessionToken=auto-2")
        #expect(slots.values[CursorSessionCookieStore.manualKeychainAccount] == "WorkosCursorSessionToken=manual-fallback")
        #expect(slots.values[CursorSessionCookieStore.importedKeychainAccount] == "WorkosCursorSessionToken=auto-2")

        let fallback = try CursorCookieResolver.resolve(
            mode: .browserAuto,
            manualCookie: nil,
            loadManual: { CursorSessionCookieStore.loadManual(read: slots.read) },
            importer: FailingImporter(),
            persistImportedCookie: { _ in Issue.record("must not persist on import failure") }
        )
        #expect(fallback == "WorkosCursorSessionToken=manual-fallback")
    }

    @Test("domain match rejects evilcursor.com-style suffix collisions")
    func domainRejectsEvilCursor() {
        #expect(CursorBrowserCookieImporter.matchesAllowedDomain("cursor.com"))
        #expect(CursorBrowserCookieImporter.matchesAllowedDomain("www.cursor.com"))
        #expect(CursorBrowserCookieImporter.matchesAllowedDomain(".cursor.com"))
        #expect(CursorBrowserCookieImporter.matchesAllowedDomain("authenticator.cursor.sh"))
        #expect(!CursorBrowserCookieImporter.matchesAllowedDomain("evilcursor.com"))
        #expect(!CursorBrowserCookieImporter.matchesAllowedDomain("notcursor.com"))
        #expect(!CursorBrowserCookieImporter.matchesAllowedDomain("cursor.com.evil.example"))
    }

    @Test("cookieHeader drops poisoned domains and weak cookies")
    func cookieHeaderFiltersDomainAndRequiresSessionName() {
        let poisoned = storeGroup(records: [
            record(domain: "evilcursor.com", name: "WorkosCursorSessionToken", value: "evil"),
            record(domain: "cursor.com", name: "_ga", value: "analytics-only"),
        ])
        #expect(CursorBrowserCookieImporter.cookieHeader(
            from: [poisoned],
            requireKnownSessionName: true
        ) == nil)

        let good = storeGroup(records: [
            record(domain: "evilcursor.com", name: "WorkosCursorSessionToken", value: "evil"),
            record(domain: "www.cursor.com", name: "WorkosCursorSessionToken", value: "good"),
            record(domain: "www.cursor.com", name: "_ga", value: "analytics"),
        ])
        let header = CursorBrowserCookieImporter.cookieHeader(
            from: [good],
            requireKnownSessionName: true
        )
        #expect(header == "WorkosCursorSessionToken=good; _ga=analytics")
        #expect(!(header?.contains("evil") ?? false))

        let weakOnly = storeGroup(records: [
            record(domain: "cursor.com", name: "_ga", value: "analytics-only"),
        ])
        #expect(CursorBrowserCookieImporter.cookieHeader(
            from: [weakOnly],
            requireKnownSessionName: true
        ) == nil)
    }

    @Test("provider fetch in browserAuto does not crash when import fails")
    func providerSurvivesImportFailure() async {
        // cookie: "" avoids CursorSessionCookieStore.loadManual() → real Keychain.
        await #expect(throws: AccountUsageError.notLoggedIn) {
            try await CursorUsageProvider(
                cookie: "",
                cookieMode: .browserAuto,
                cookieImporter: FailingImporter(),
                transport: MissingTransport()
            ).fetch()
        }
    }

    @Test("browserAuto import timeout surfaces timedOut")
    func importTimeout() async {
        let provider = CursorUsageProvider(
            cookie: "",
            cookieMode: .browserAuto,
            cookieImporter: SlowImporter(delayNanoseconds: 500_000_000),
            transport: MissingTransport(),
            importTimeout: 0.05
        )
        await #expect(throws: AccountUsageError.timedOut) {
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

    private struct SlowImporter: CursorBrowserCookieImporting {
        let delayNanoseconds: UInt64
        func importSessionCookieHeader(allowKeychainPrompt: Bool) throws -> String {
            // Sleep past the provider importTimeout, then fail — never returns a
            // cookie that could be persisted into the user's real Keychain.
            Thread.sleep(forTimeInterval: Double(delayNanoseconds) / 1_000_000_000)
            throw AccountUsageError.notLoggedIn
        }
    }

    private struct MissingTransport: CursorUsageTransport {
        func cursorData(for request: URLRequest) async throws -> (Data, URLResponse) {
            Issue.record("network should not run without a cookie")
            throw URLError(.badURL)
        }
    }

    private func record(domain: String, name: String, value: String) -> BrowserCookieRecord {
        BrowserCookieRecord(
            domain: domain,
            name: name,
            path: "/",
            value: value,
            expires: nil,
            isSecure: true,
            isHTTPOnly: true
        )
    }

    private final class InMemoryCookieSlots: @unchecked Sendable {
        var values: [String: String]
        var writeCount = 0

        init(_ values: [String: String] = [:]) {
            self.values = values
        }

        func read(_ account: String) -> String? { values[account] }

        func write(_ value: String?, _ account: String) -> OSStatus {
            writeCount += 1
            if let value, !value.isEmpty {
                values[account] = value
            } else {
                values.removeValue(forKey: account)
            }
            return errSecSuccess
        }
    }

    private func storeGroup(records: [BrowserCookieRecord]) -> BrowserCookieStoreRecords {
        BrowserCookieStoreRecords(
            store: BrowserCookieStore(
                browser: .chrome,
                profile: BrowserProfile(id: "test", name: "Test"),
                kind: .primary,
                label: "Test",
                databaseURL: nil
            ),
            records: records
        )
    }
}
