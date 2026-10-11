import CryptoKit
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Grok Bot result bridge")
struct GrokBotResultTests {
    private func result(now: Date, text: String = "通知：接続を確認しました。") -> GrokBotResult {
        .init(version: 1, evidence: .notification, id: "message-1", botID: "bot-1",
              conversationID: "chat-1", turnID: "message-1", botName: "Test Bot",
              title: "Grok Bot notification", text: text, completedAt: now)
    }

    @Test("Ingest credential cannot control the hub; receipts survive retry and reject conflicts")
    func receipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let store = SessionStore(resultClock: { now })
        let inbox = GrokBotResultInbox(token: "ingest-only", directory: root)
        let server = VibeBuddyServer(store: store, token: "phone-control", grokBotResults: inbox)
        let event = result(now: now)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let body = ByteBuffer(data: try encoder.encode(event))
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/grok-bot/result", method: .post,
                                     headers: [.authorization: "Bearer phone-control"], body: body) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/snapshot", method: .get,
                                     headers: [.authorization: "Bearer ingest-only"]) { #expect($0.status == .unauthorized) }
            for _ in 0..<2 {
                try await client.execute(uri: "/grok-bot/result", method: .post,
                                         headers: [.authorization: "Bearer ingest-only"], body: body) { #expect($0.status == .ok) }
            }
            let conflict = ByteBuffer(data: try encoder.encode(result(now: now, text: "Changed evidence")))
            try await client.execute(uri: "/grok-bot/result", method: .post,
                                     headers: [.authorization: "Bearer ingest-only"], body: conflict) { #expect($0.status == .conflict) }
        }
        let snapshot = await store.snapshot(now: now)
        let session = try #require(snapshot.sessions.first { $0.id == event.sessionID })
        #expect(session.agent == .grokBot)
        #expect(session.completionID == event.id)
        let read = await store.completionBody(sessionID: event.sessionID, completionID: event.id)
        #expect(read.text == event.text)
        let restarted = GrokBotResultInbox(token: "ingest-only", directory: root)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try await restarted.receive(decoder.decode(GrokBotResult.self, from: encoder.encode(event)), store: store, now: now))
        #expect(await store.snapshot(now: now).sessions.filter { $0.id == event.sessionID }.count == 1)
        let emptyStore = SessionStore(resultClock: { now })
        #expect(try await restarted.receive(decoder.decode(GrokBotResult.self, from: encoder.encode(event)), store: emptyStore, now: now))
        #expect(await emptyStore.snapshot(now: now).sessions.isEmpty)
    }

    @Test("Cache observes new text only, includes groups, rejects another account and never replays history")
    func cache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = "test-owner"
        let scope = SHA256.hash(data: Data(subject.utf8)).map { String(format: "%02x", $0) }.joined()
        let monitor = GrokBotCacheMonitor(directory: root, scope: { scope })
        let start = Date()
        let rosterKey = "sand.client.slice.account.\(subject).roster.last-roster"
        try JSONSerialization.data(withJSONObject: ["value": ["rows": [["id": "bot", "name": "Bot", "isGroup": false]]]])
            .write(to: root.appendingPathComponent(Self.base32(rosterKey) + ".blob"))
        func write(_ subject: String, _ id: String, _ date: Date, type: String = "text", author: String = "bot", name: String = "Bot") throws {
            let key = "sand.client.slice.account.\(subject).transcript.replicas.group-chat"
            let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "value": ["entries": [
                ["kind": "send-message", "id": id, "timestampMs": date.timeIntervalSince1970 * 1000,
                 "author": ["id": author, "name": name], "message": ["type": type, "content": "Test notice"]]
            ]]])
            try data.write(to: root.appendingPathComponent(Self.base32(key) + ".blob"), options: .atomic)
        }
        try write(subject, "old", start.addingTimeInterval(-100))
        #expect(try await monitor.poll(now: start).isEmpty)
        try write("other-owner", "other", start.addingTimeInterval(1))
        try write(subject, "new", start.addingTimeInterval(1), name: "  ")
        let notices = try await monitor.poll(now: start.addingTimeInterval(2))
        #expect(notices.count == 1)
        #expect(notices.first?.id == "new")
        #expect(notices.first?.botName == "Bot")
        #expect(notices.first?.evidence == .notification)
        #expect(try await monitor.poll(now: start.addingTimeInterval(3)).isEmpty)
        try write(subject, "secret", start.addingTimeInterval(4), type: "secret-request")
        #expect(try await monitor.poll(now: start.addingTimeInterval(5)).isEmpty)
        try write(subject, "human", start.addingTimeInterval(6), author: "unknown-human")
        #expect(try await monitor.poll(now: start.addingTimeInterval(7)).isEmpty)
    }

    @Test("Delayed receipts remain readable and Japanese fallback describes delivery only")
    func delayedReceipt() async throws {
        let now = Date()
        let store = SessionStore(sourceID: "mac", resultClock: { now })
        let event = result(now: now.addingTimeInterval(-120))
        await store.ingestGrokBotResult(event, now: now)
        let session = try #require(await store.snapshot(now: now).sessions.first)
        #expect(session.statusSince == now)
        guard case .ready = await store.completionResult(sessionID: event.sessionID, completionID: event.id) else {
            Issue.record("A newly delivered notification expired using the remote send time"); return
        }
        let speech = try #require(await store.presentation(.init(sourceID: "mac",
            target: .completion(sessionID: event.sessionID, completionID: event.id))))
        #expect(speech.text.contains("通知が届きました"))
        #expect(!speech.text.contains("応答が終了"))
    }

    @Test("Desktop direct notifications omit author and resolve their Bot from the roster")
    func directNotification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = "test-owner"
        let scope = SHA256.hash(data: Data(subject.utf8)).map { String(format: "%02x", $0) }.joined()
        func write(_ suffix: String, _ value: [String: Any]) throws {
            let key = "sand.client.slice.account.\(subject)." + suffix
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "value": value])
                .write(to: root.appendingPathComponent(Self.base32(key) + ".blob"), options: .atomic)
        }
        try write("roster.last-roster", ["rows": [["id": "direct-bot", "name": "Test Bot", "isGroup": false]]])
        let monitor = GrokBotCacheMonitor(directory: root, scope: { scope })
        let now = Date()
        #expect(try await monitor.poll(now: now).isEmpty)
        try write("transcript.replicas.direct-bot", ["entries": [["kind": "send-message", "id": "t1s2",
            "timestampMs": now.addingTimeInterval(1).timeIntervalSince1970 * 1000,
            "message": ["type": "text", "content": "A real-shaped direct notification"]]]])
        let results = try await monitor.poll(now: now.addingTimeInterval(2))
        #expect(results.count == 1)
        #expect(results.first?.botName == "Test Bot")
        #expect(try await monitor.poll(now: now.addingTimeInterval(3)).isEmpty)
    }

    private static func base32(_ text: String) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, buffer = 0, output = ""
        for byte in text.utf8 {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 { bits -= 5; output.append(alphabet[(buffer >> bits) & 31]) }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }
}
