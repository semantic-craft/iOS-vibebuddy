import Testing
import Foundation
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Remote connection handoff")
struct RemoteConnectionSyncTests {
    @Test("Only the current request can confirm; failed checks can be retried before expiry")
    func receipts() async throws {
        let sync = RemoteConnectionSyncStore()
        let now = Date()
        let first = try #require(await sync.propose(deviceID: "phone", sourceID: "mac", host: "100.64.0.8", port: 9876, now: now))
        func receipt(_ id: String, _ outcome: RemoteConnectionReceipt.Outcome) -> RemoteConnectionReceipt {
            .init(requestID: id, deviceID: "phone", sourceID: "mac", outcome: outcome)
        }
        #expect(await sync.receive(receipt(first.requestID, .received), now: now))
        #expect(await sync.receive(receipt(first.requestID, .unreachable), now: now))
        #expect(await sync.pending(for: "phone", now: now) == first)
        #expect(await sync.receive(receipt(first.requestID, .received), now: now.addingTimeInterval(1)))
        let failed = await sync.transfer(for: "phone")
        #expect(failed?.outcome == .unreachable)
        #expect(failed?.updatedAt == now)
        #expect(await sync.receive(receipt(first.requestID, .confirmed), now: now))
        #expect(await sync.receive(receipt(first.requestID, .confirmed), now: now.addingTimeInterval(600)))
        #expect(await sync.receive(receipt(first.requestID, .unreachable), now: now) == false)
        #expect(await sync.pending(for: "phone", now: now) == nil)
        let next = try #require(await sync.propose(deviceID: "phone", sourceID: "mac", host: "100.64.0.9", port: 9876, now: now))
        #expect(await sync.receive(receipt(first.requestID, .confirmed), now: now) == false)
        #expect(await sync.receive(receipt(next.requestID, .confirmed), now: now.addingTimeInterval(301)) == false)
        #expect(await sync.receive(receipt(next.requestID, .cancelled), now: now))
        #expect(await sync.receive(receipt(next.requestID, .received), now: now.addingTimeInterval(1)))
        #expect(await sync.transfer(for: "phone")?.outcome == .cancelled)
        #expect(await sync.pending(for: "phone", now: now) == next)
        #expect(await sync.receive(receipt(next.requestID, .received), now: now.addingTimeInterval(301)) == false)
        await sync.cancel(for: "phone")
        #expect(await sync.receive(receipt(next.requestID, .confirmed), now: now) == false)
    }

    @Test("Pairing consent and bearer protect delivery and receipts")
    func routes() async throws {
        let devices = DeviceTokens()
        let sync = RemoteConnectionSyncStore()
        let server = VibeBuddyServer(store: SessionStore(), token: "sync-test", deviceTokens: devices, connectionSync: sync)
        let proposal = try #require(await sync.propose(deviceID: "phone", sourceID: "mac", host: "100.64.0.8", port: 9876))
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/connection-sync?deviceID=phone", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/connection-sync?deviceID=phone", method: .get,
                                     headers: [.authorization: "Bearer sync-test"]) { #expect($0.status == .forbidden) }
            await devices.acceptNewRegistrations()
            try await client.execute(uri: "/device", method: .post, headers: [.authorization: "Bearer sync-test"],
                                     body: ByteBuffer(string: #"{"deviceID":"phone","name":"Test iPhone"}"#)) {
                #expect($0.status == .ok)
            }
            try await client.execute(uri: "/connection-sync?deviceID=phone", method: .get,
                                     headers: [.authorization: "Bearer sync-test"]) {
                #expect($0.status == .ok)
                let decoded = try? JSONDecoder().decode(RemoteConnectionProposal.self, from: Data(buffer: $0.body))
                #expect(decoded == proposal)
            }
            let receipt = RemoteConnectionReceipt(requestID: proposal.requestID, deviceID: "phone", sourceID: "mac", outcome: .confirmed)
            let body = ByteBuffer(bytes: try JSONEncoder().encode(receipt))
            try await client.execute(uri: "/connection-sync/receipt", method: .post,
                                     headers: [.authorization: "Bearer sync-test"], body: body) { #expect($0.status == .ok) }
            try await client.execute(uri: "/connection-sync?deviceID=phone", method: .get,
                                     headers: [.authorization: "Bearer sync-test"]) { #expect($0.status == .noContent) }
            await devices.forgetAll()
            try await client.execute(uri: "/connection-sync/receipt", method: .post,
                                     headers: [.authorization: "Bearer sync-test"], body: body) { #expect($0.status == .forbidden) }
        }
    }

    @Test("Never send a server URL or a different device or Mac's request")
    func boundaries() async throws {
        let sync = RemoteConnectionSyncStore()
        #expect(await sync.propose(deviceID: "p", sourceID: "s", host: "headscale.example.com", port: 9876) == nil)
        let p = try #require(await sync.propose(deviceID: "p", sourceID: "s", host: "100.64.0.8", port: 9876))
        #expect(await sync.pending(for: "other") == nil)
        #expect(await sync.receive(.init(requestID: p.requestID, deviceID: "p", sourceID: "other", outcome: .confirmed)) == false)
        #expect(await sync.receive(.init(requestID: p.requestID, deviceID: "other", sourceID: "s", outcome: .confirmed)) == false)
    }
}
