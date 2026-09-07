import Foundation
import SQLite3
import Testing
@testable import VibeBuddyMacCore

struct CursorLocalSessionTests {
    private func token(expiration: Double = 1000) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["sub": "auth0|user_test", "exp": expiration])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(payload).test"
    }
    @Test func appSessionUsesReadOnlyDatabase() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let value = try token()
        #expect(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(value)');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(try CursorLocalSession.cookieHeader(path: path, now: Date(timeIntervalSince1970: 900)) == "WorkosCursorSessionToken=user_test%3A%3A\(value)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
        #expect(throws: AccountUsageError.notLoggedIn) { try CursorLocalSession.cookieHeader(path: path, now: Date(timeIntervalSince1970: 950)) }
    }
    @Test func independentPoolsDoNotUseOnDemandBudget() throws {
        let json = #"{"individualUsage":{"plan":{"autoPercentUsed":22,"apiPercentUsed":83,"totalPercentUsed":50},"onDemand":{"used":999,"limit":1000}}}"#
        let snapshot = try CursorUsageSummaryDecoder.decode(Data(json.utf8), fetchedAt: Date())
        #expect(snapshot.primary?.usedPercent == 22)
        #expect(snapshot.primary?.label == "Cursor Models")
        #expect(snapshot.secondary?.usedPercent == 83)
        #expect(snapshot.secondary?.label == "Other Models")
    }
}
