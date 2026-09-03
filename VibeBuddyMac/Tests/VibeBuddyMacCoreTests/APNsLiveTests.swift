import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VibeBuddyMacCore

/// Live diagnostic: only runs when APNS_* env vars are set. Sends a push to a
/// dummy device token; a `400 BadDeviceToken` proves the key/JWT/auth chain
/// works (a `403` would mean the key or signing is wrong).
@Suite("APNs live auth")
struct APNsLiveTests {
    @Test("dummy push authenticates with APNs")
    func auth() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["APNS_KEY_PATH"], let keyID = env["APNS_KEY_ID"],
              let teamID = env["APNS_TEAM_ID"], let bundle = env["APNS_BUNDLE_ID"],
              let pem = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            print("APNS_* not set — skipping live APNs test")
            return
        }

        let jwt = try APNsJWT(teamID: teamID, keyID: keyID, p8PEM: pem)
        let provider = try jwt.token(now: Date())
        let host = env["APNS_SANDBOX"] == "1" ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        let dummy = String(repeating: "ab", count: 32)

        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(dummy)")!)
        request.httpMethod = "POST"
        request.setValue("bearer \(provider)", forHTTPHeaderField: "authorization")
        request.setValue(bundle, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.httpBody = Data(#"{"aps":{"alert":"test"}}"#.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        let reason = String(data: data, encoding: .utf8) ?? ""
        print("APNs status=\(http.statusCode) reason=\(reason)")

        #expect(http.statusCode == 400)        // BadDeviceToken => auth chain works
        #expect(reason.contains("BadDeviceToken"))
    }
}
