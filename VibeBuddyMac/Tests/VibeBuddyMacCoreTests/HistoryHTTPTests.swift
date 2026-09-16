import Foundation
import Testing
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Authenticated history paging")
struct HistoryHTTPTests {
    private func fixture() throws -> (URL, URL, HistoryHTTPReader) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-http-" + UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("native.jsonl")
        var lines = [#"{"type":"session_meta","payload":{"id":"native","cwd":"/private/project"}}"#]
        for i in 0..<65 {
            lines.append(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"message-NUMBER"}]}}"#.replacingOccurrences(of: "NUMBER", with: String(format: "%02d", i)))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = HistoryHTTPReader(repository: {
            SessionHistoryRepository(claudeHome: root, codexHome: root, cursorHome: root,
                cacheDirectory: root.appendingPathComponent("empty"), readOnly: true)
        })
        return (root, file, reader)
    }
    private func page(_ result: HistoryHTTPReader.Result) throws -> HistoryPage {
        #expect(result.status == 200)
        return try JSONDecoder().decode(HistoryPage.self, from: result.data)
    }

    @Test func exactPagesAndSameMetadataRewrite() async throws {
        let (root, file, reader) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let uri = "/history?sourceID=mac&key=codex:native&limit=30"
        let tail = try page(await reader.read(uri: uri, sourceID: "mac"))
        #expect(tail.start == 35 && tail.end == 65)
        let cursor = try #require(tail.nextCursor)
        let olderURI = uri + "&cursor=" + cursor
        let older = try page(await reader.read(uri: olderURI, sourceID: "mac"))
        let repeated = try page(await reader.read(uri: olderURI, sourceID: "mac"))
        #expect(older.start == 5 && older.end == 35 && older.messages == repeated.messages)
        #expect(Set(older.messages.map(\.id)).isDisjoint(with: tail.messages.map(\.id)))
        #expect(!String(decoding: await reader.read(uri: uri, sourceID: "mac").data, as: UTF8.self).contains("/private/project"))
        let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "message-00", with: "changed-00")
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let changed = await reader.read(uri: olderURI, sourceID: "mac")
        #expect(changed.status == 409)
        #expect(try JSONDecoder().decode(HistoryFailure.self, from: changed.data).reason == "revision_changed")
    }

    @Test func authenticationAndMalformedInputs() async throws {
        let (root, _, reader) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let server = VibeBuddyServer(store: SessionStore(sourceID: "mac"), token: "test", historyReader: reader)
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/history?path=/secret", method: .get) { #expect($0.status == .unauthorized) }
            for uri in ["/history?sourceID=mac&key=codex:native&key=codex:other", "/history?sourceID=mac&key=codex:native&path=/secret", "/history?sourceID=mac&key=codex:../x"] {
                try await client.execute(uri: uri, method: .get, headers: [.authorization: "Bearer test"]) { #expect($0.status == .badRequest) }
            }
            try await client.execute(uri: "/history?sourceID=mac&key=codex:native", method: .get, headers: [.authorization: "Bearer test"]) { #expect($0.status == .ok) }
        }
        #expect(await reader.read(uri: "/history?sourceID=other&key=codex:native", sourceID: "mac").status == 409)
        #expect(await reader.read(uri: "/history?sourceID=mac&key=grok-build:native", sourceID: "mac").status == 422)
        #expect(await reader.read(uri: "/history?sourceID=mac&key=codex:missing", sourceID: "mac").status == 404)
    }

    @Test func cursorCannotCrossSourceOrSession() async throws {
        let (root, _, reader) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let tail = try page(await reader.read(uri: "/history?sourceID=mac&key=codex:native", sourceID: "mac"))
        let cursor = try #require(tail.nextCursor)
        #expect(await reader.read(uri: "/history?sourceID=new&key=codex:native&cursor=" + cursor, sourceID: "new").status == 409)
        #expect(await reader.read(uri: "/history?sourceID=mac&key=codex:other&cursor=" + cursor, sourceID: "mac").status == 409)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("empty/index.json").path))
    }
}
