import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("Grok web credits contract")
struct GrokWebCreditsTests {
    // Descriptor-derived active weekly period, no percentage field. Same shape
    // observed on 2026-09-07; no credentials or account identifiers.
    static let zero = hex("0a1442120802120608d1a0f5d4061a0608d1959ad506")
    let now = Date(timeIntervalSince1970: 1_788_750_000)

    @Test("a missing gRPC completion trailer cannot manufacture zero usage")
    func requiresCompletion() {
        let incomplete = Data([0, 0, 0, 0, UInt8(Self.zero.count)]) + Self.zero
        #expect(throws: (any Error).self) { try GrokWebCredits.decode(incomplete, now: now) }
    }

    @Test("only a complete active protobuf period can supply an implicit zero")
    func implicitZeroContract() throws {
        let reading = try GrokWebCredits.decode(Self.zero, now: now)
        #expect(reading.percent == 0)
        #expect(reading.isImplicitZero)
        #expect(throws: (any Error).self) {
            try GrokWebCredits.decode(Self.zero, now: Date(timeIntervalSince1970: 1_789_300_000))
        }
        // Malformed declared onDemandCap submessage after a valid period.
        let corrupt = Self.hex("0a1742120802120608d1a0f5d4061a0608d1959ad506120180")
        #expect(throws: (any Error).self) { try GrokWebCredits.decode(corrupt, now: now) }
        #expect(throws: (any Error).self) { try GrokWebCredits.decode(Self.zero + Data([0]), now: now) }
    }

    static func hex(_ string: String) -> Data {
        Data(stride(from: 0, to: string.count, by: 2).map { offset in
            let start = string.index(string.startIndex, offsetBy: offset)
            return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
