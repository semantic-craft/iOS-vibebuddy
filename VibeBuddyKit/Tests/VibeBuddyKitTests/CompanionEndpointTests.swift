import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Companion addresses")
struct CompanionEndpointTests {
    @Test func privateAddressAndQueries() throws {
        let endpoint = try #require(CompanionEndpoint(host: " My-Mac.example.ts.net ", port: 9876))
        #expect(endpoint.isTailscale)
        let url = try #require(endpoint.url(path: "recent-output", queryItems: [.init(name: "sessionId", value: "a&b?c")]))
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "my-mac.example.ts.net")
        #expect(parts.queryItems == [.init(name: "sessionId", value: "a&b?c")])
        #expect(endpoint.url(path: "ws", webSocket: true)?.scheme == "ws")
        #expect(CompanionEndpoint(host: "100.64.0.1", port: 9876)?.isTailscale == true)
        #expect(CompanionEndpoint(host: "192.168.1.1", port: 9876)?.isTailscale == false)
    }
    @Test func rejectHostInjectionAndInvalidPorts() {
        for host in ["https://mac", "mac/path", "user@mac", "mac?token=x", "mac#x", "mac:80", "100.999.0.1", "mac..ts.net", "-mac"] {
            #expect(CompanionEndpoint(host: host, port: 9876) == nil)
        }
        #expect(CompanionEndpoint(host: "mac.local", port: 0) == nil)
        #expect(CompanionEndpoint(host: "mac.local", port: 65536) == nil)
    }
    @Test func legacyPairingUnchanged() throws {
        let json = Data(#"{"host":"100.64.0.1","port":9876,"token":"fixture"}"#.utf8)
        let pairing = try JSONDecoder().decode(PairingPayload.self, from: json)
        #expect(pairing.isValidConnection)
        #expect(pairing.companionURL(path: "decision")?.absoluteString == "http://100.64.0.1:9876/decision")
        #expect(try JSONDecoder().decode(PairingPayload.self, from: JSONEncoder().encode(pairing)) == pairing)
    }
}
