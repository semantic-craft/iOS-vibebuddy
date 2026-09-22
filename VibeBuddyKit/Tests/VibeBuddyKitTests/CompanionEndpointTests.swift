import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Companion addresses")
struct CompanionEndpointTests {
    @Test func headscaleAddressRetainsPairing() throws {
        let lan = PairingPayload(host: "192.168.1.20", port: 9876, token: "fixture", macName: "Home Mac")
        let remote = try #require(lan.usingTailnetIPv4(" 100.64.0.8 ", port: 18765))
        #expect(remote.host == "100.64.0.8")
        #expect(remote.port == 18765)
        #expect(remote.token == lan.token)
        #expect(remote.macName == lan.macName)
        #expect(remote.companionURL(path: "ws", webSocket: true)?.absoluteString == "ws://100.64.0.8:18765/ws")
        for host in ["100.63.255.255", "100.128.0.1", "https://headscale.example.com", "mac.tail.example.com", "100.64.example.0.1", "192.168.1.20"] {
            #expect(lan.usingTailnetIPv4(host, port: 9876) == nil)
        }
        #expect(lan.usingTailnetIPv4("100.127.255.254", port: 9876) != nil)
        #expect(lan.usingTailnetIPv4("100.64.0.8", port: 0) == nil)
    }

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
    /// Found in `pairing.tailscaleHost` on a real Mac: a block of unrelated
    /// script had been written into the address field. It is inert only while
    /// the remote connection method is off, so the check has to hold on the
    /// value itself, not on the surrounding setting.
    @Test func scriptBlobIsNeverAHost() throws {
        let blob = #"""
        var addon = await (ChromeUtils.importESModule("resource://gre/modules/AddonManager.sys.mjs").AddonManager).getAddonByID("zotero-bridge@glaux.local");
        return JSON.stringify({zotero: Zotero.version, bridge: addon && addon.version, active: addon && addon.isActive});
        """#
        #expect(CompanionEndpoint.normalizedHost(blob) == nil)
        #expect(CompanionEndpoint(host: blob, port: 9876) == nil)

        // The blob is long enough that the length cap alone would reject it,
        // so pin the character rules too, on a short excerpt of the same
        // script: otherwise this passes even if the per-label check is gone.
        #expect(blob.count > 253)
        let excerpt = "zotero-bridge@glaux.local"
        #expect(excerpt.count < 253)
        #expect(CompanionEndpoint.normalizedHost(excerpt) == nil)

        let lan = PairingPayload(host: "192.168.1.20", port: 9876, token: "fixture", macName: "Home Mac")
        #expect(lan.usingTailnetIPv4(blob, port: 9876) == nil)
        let advertised = PairingPayload(host: blob, port: 9876, token: "fixture", macName: "Home Mac")
        #expect(!advertised.isValidConnection)
        #expect(advertised.companionURL(path: "ws", webSocket: true) == nil)

        // The shape, not just this one string: over the length cap, and well
        // under it but still impossible.
        for host in [String(repeating: "a", count: 254), "echo hi", "100.64.0.8 && curl evil.example", "100.64.0.8\nrm -rf /"] {
            #expect(CompanionEndpoint.normalizedHost(host) == nil, "accepted: \(host)")
        }
    }

    /// The host check is reused to vet a *persisted* address on read. It must
    /// keep normalizing good input, and it must reject a half-typed address —
    /// which is why the Mac applies it on load only, never on every keystroke.
    @Test func normalizedHostTrimsAndLowercases() {
        #expect(CompanionEndpoint.normalizedHost(" My-Mac.Example.TS.net \n") == "my-mac.example.ts.net")
        #expect(CompanionEndpoint.normalizedHost("100.64.0.8") == "100.64.0.8")
        for partial in ["", "   ", "100.", "100.64.", "-"] {
            #expect(CompanionEndpoint.normalizedHost(partial) == nil, "accepted: \(partial)")
        }
    }

    @Test func legacyPairingUnchanged() throws {
        let json = Data(#"{"host":"100.64.0.1","port":9876,"token":"fixture"}"#.utf8)
        let pairing = try JSONDecoder().decode(PairingPayload.self, from: json)
        #expect(pairing.isValidConnection)
        #expect(pairing.companionURL(path: "decision")?.absoluteString == "http://100.64.0.1:9876/decision")
        #expect(try JSONDecoder().decode(PairingPayload.self, from: JSONEncoder().encode(pairing)) == pairing)
    }
}
