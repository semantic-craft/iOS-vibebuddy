import Foundation
import Security
import Testing
@testable import VibeBuddyKit

@Suite("Cloudflare companion transport")
struct CompanionTransportTests {
    private let direct = PairingPayload(host: "192.168.1.2", port: 9876, token: "mac-fixture")

    @Test func oldPairingsAndPrivateHandoffRemainDirect() throws {
        let old = try JSONDecoder().decode(PairingPayload.self, from: Data(#"{"host":"192.168.1.2","port":9876,"token":"fixture"}"#.utf8))
        #expect(!old.isCloudflare)
        #expect(old.companionURL(path: "ws", webSocket: true)?.scheme == "ws")
        let remote = try #require(old.usingCloudflare(origin: "https://mac.example.com", credentialID: "test-id"))
        let handoff = try #require(remote.usingPrivateConnectionIPv4("10.0.0.3", port: 9876))
        #expect(handoff.cloudflareCredentialID == nil)
        #expect(handoff.companionURL(path: "snapshot")?.scheme == "http")
        #expect(remote.usingTailnetIPv4("100.64.0.2", port: 9876)?.cloudflareCredentialID == nil)
    }

    @Test func httpAndWebsocketShareOriginBoundAuthentication() throws {
        let credentials = try #require(CloudflareCredentials(origin: " https://MAC.example.com:443/ ", clientID: "device.access", clientSecret: "cfast_fixture"))
        #expect(credentials.origin == "https://mac.example.com")
        let pairing = try #require(direct.usingCloudflare(origin: credentials.origin, credentialID: "fixture-id"))
        for websocket in [false, true] {
            let url = try #require(pairing.companionURL(path: "snapshot", webSocket: websocket))
            let request = try CompanionTransport.prepare(URLRequest(url: url), pairing: pairing, credentials: credentials)
            #expect(request.url?.scheme == (websocket ? "wss" : "https"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mac-fixture")
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == credentials.clientID)
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == credentials.clientSecret)
        }
        for url in ["http://mac.example.com/snapshot", "https://other.example.com/snapshot", "https://mac.example.com:444/snapshot", "https://user@mac.example.com/snapshot"] {
            #expect(throws: CompanionTransportError.invalidAddress) {
                try CompanionTransport.prepare(URLRequest(url: URL(string: url)!), pairing: pairing, credentials: credentials)
            }
        }
        let other = try #require(CloudflareCredentials(origin: "https://other.example.com", clientID: "id", clientSecret: "secret"))
        #expect(throws: CompanionTransportError.credentialOriginMismatch) {
            try CompanionTransport.prepare(URLRequest(url: pairing.companionURL(path: "snapshot")!), pairing: pairing, credentials: other)
        }
        var plain = URLRequest(url: direct.companionURL(path: "snapshot")!)
        plain.setValue("must-strip", forHTTPHeaderField: "CF-Access-Client-Secret")
        let clean = try CompanionTransport.prepare(plain, pairing: direct, credentials: credentials)
        #expect(clean.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }

    @Test func invalidInputsAndLoginResponsesFailClosed() throws {
        for origin in ["http://mac.example.com", "https://user@mac.example.com", "https://mac.example.com/a", "https://mac.example.com?x", "https://mac.example.com#x", "https://mac.example.com:444"] {
            #expect(CloudflareCredentials(origin: origin, clientID: "id", clientSecret: "secret") == nil)
        }
        #expect(CloudflareCredentials(origin: "https://mac.example.com", clientID: "id\r\nheader: bad", clientSecret: "secret") == nil)
        let url = URL(string: "https://mac.example.com/snapshot")!
        for status in [302, 307, 401, 403] {
            #expect(throws: CompanionTransportError.authentication) {
                try CompanionTransport.validateCloudflareResponse(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        #expect(throws: CompanionTransportError.authentication) {
            try CompanionTransport.validateCloudflareResponse(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!)
        }
        try CompanionTransport.validateCloudflareResponse(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }

    @Test func unavailableKeychainAndWriteFailureAreExplicitWithoutDeletion() throws {
        let credentials = try #require(CloudflareCredentials(origin: "https://mac.example.com", clientID: "id", clientSecret: "secret"))
        let denied = KeychainStore.Operations(update: { _, _ in errSecInteractionNotAllowed }, add: { _ in
            Issue.record("must not add after failed update"); return errSecSuccess
        }, delete: { _ in
            Issue.record("must not delete existing credential after failed update"); return errSecSuccess
        }, copyMatching: { _ in (errSecInteractionNotAllowed, nil) })
        #expect(throws: CompanionTransportError.credentialsUnavailable) { try CloudflareCredentialStore.load(id: "fixture", operations: denied) }
        #expect(throws: CompanionTransportError.keychainWriteFailed) { try CloudflareCredentialStore.save(credentials, id: "fixture", operations: denied) }
    }
    #if os(macOS)
    @Test func realSessionDoesNotFollowSameOrCrossOriginRedirects() async throws {
        // Two real local HTTP servers verify URLSession's redirect delegate,
        // including a different origin. All tokens are disposable fixtures.
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
import http.server, threading
hits = 0
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global hits
        if self.path == '/target':
            hits += 1
        if self.path in ['/same', '/cross']:
            self.send_response(302)
            port = self.server.server_port if self.path == '/same' else secondary.server_port
            self.send_header('Location', 'http://127.0.0.1:%d/target' % port)
            self.end_headers()
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(str(hits).encode())
    def log_message(self, *args): pass
secondary = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=secondary.serve_forever, daemon=True).start()
primary = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(primary.server_port, flush=True)
primary.serve_forever()
"""#]
        let output = Pipe()
        server.standardOutput = output
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
        }
        let port = try #require(Int(String(decoding: line, as: UTF8.self)))
        let pairing = PairingPayload(host: "127.0.0.1", port: port, token: "disposable-bearer")
        for path in ["same", "cross"] {
            let (_, response) = try await CompanionTransport.data(for: URLRequest(url: pairing.companionURL(path: path)!), pairing: pairing)
            #expect((response as? HTTPURLResponse)?.statusCode == 302)
        }
        let (data, _) = try await CompanionTransport.data(for: URLRequest(url: pairing.companionURL(path: "count")!), pairing: pairing)
        #expect(String(decoding: data, as: UTF8.self) == "0")
    }
    #endif

}
