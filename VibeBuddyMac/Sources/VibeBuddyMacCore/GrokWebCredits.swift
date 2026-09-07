import Foundation

/// The narrow billing schema published by grok.com's web client. No cookie import.
/// Descriptor: cdn.grok.com/_next/static/chunks/32g78bk5hhe1q.js (2026-09-07).
public enum GrokWebCredits {
    public static let endpoint = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!

    public struct Reading: Sendable {
        public let percent: Double
        public let start: Date
        public let end: Date
        public let isImplicitZero: Bool
    }

    static func fetch(token: String, transport: GrokCreditsProxyTransport, now: Date) async throws -> Reading {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = Data(repeating: 0, count: 5)
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("VibeBuddy", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.proxyData(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AccountUsageError.providerUnavailable
        }
        if let status = http.value(forHTTPHeaderField: "grpc-status"), status != "0" {
            throw AccountUsageError.providerUnavailable
        }
        return try decode(data, now: now)
    }

    /// Requires a complete current period even for a published percentage, so
    /// historical values cannot be attached to a newer ACP billing period.
    public static func decode(_ data: Data, now: Date) throws -> Reading {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw AccountUsageError.incompatibleFormat }
        var payload = data
        if data.first == 0 || data.first == 0x80 {
            var cursor = Cursor(data)
            var message: Data?
            var trailersSeen = false
            while !cursor.atEnd {
                let flags = try cursor.byte()
                let lengthBytes = try cursor.bytes(4)
                let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
                let body = try cursor.bytes(length)
                if flags == 0, message == nil, !trailersSeen { message = body }
                else if flags == 0x80, !trailersSeen {
                    trailersSeen = true
                    guard let text = String(data: body, encoding: .utf8) else { throw AccountUsageError.incompatibleFormat }
                    let statuses = text.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("grpc-status:") }
                    guard statuses.count == 1,
                          statuses[0].split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) == "0" else {
                        throw AccountUsageError.providerUnavailable
                    }
                } else { throw AccountUsageError.incompatibleFormat }
            }
            guard let message, trailersSeen else { throw AccountUsageError.incompatibleFormat }
            payload = message
        }
        let response = try Message(payload)
        let config = try Message(response.requiredBytes(1))
        try config.validate(.config)
        let period = try Message(config.requiredBytes(8))
        let type = try period.integer(1)
        guard type == 1 || type == 2 else { throw AccountUsageError.incompatibleFormat }
        let start = try timestamp(period.requiredBytes(2))
        let end = try timestamp(period.requiredBytes(3))
        guard start <= now, now < end else { throw AccountUsageError.incompatibleFormat }
        let percent = try config.float(1)
        // A product breakdown without its total does not establish zero.
        guard percent != nil || config.fields[7] == nil else { throw AccountUsageError.incompatibleFormat }
        guard percent.map({ $0.isFinite && (0...100).contains($0) }) ?? true else {
            throw AccountUsageError.incompatibleFormat
        }
        // proto3 implicit scalar presence: default zero is omitted. Only this
        // validated active-period protobuf contract supplies an implicit zero.
        return Reading(percent: percent ?? 0, start: start, end: end, isImplicitZero: percent == nil)
    }

    private static func timestamp(_ data: Data) throws -> Date {
        let message = try Message(data)
        guard let seconds = try message.integer(1), seconds <= 253_402_300_799 else {
            throw AccountUsageError.incompatibleFormat
        }
        let nanos = try message.integer(2) ?? 0
        guard nanos < 1_000_000_000 else { throw AccountUsageError.incompatibleFormat }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9)
    }

    private enum Schema { case config, period, timestamp, cent, history, product, cycle }

    private enum Value {
        case integer(UInt64), bytes(Data), float(Double), fixed64
    }

    /// Unknown fields are skipped as opaque wire values, never scanned for a
    /// percentage. Duplicate queried singular fields and wrong wire types fail.
    private struct Message {
        var fields: [UInt64: [Value]] = [:]
        init(_ data: Data) throws {
            var cursor = Cursor(data)
            while !cursor.atEnd {
                let tag = try cursor.varint()
                let field = tag >> 3
                guard field > 0, field <= 536_870_911 else { throw AccountUsageError.incompatibleFormat }
                let value: Value
                switch tag & 7 {
                case 0: value = .integer(try cursor.varint())
                case 1: _ = try cursor.bytes(8); value = .fixed64
                case 2:
                    let count = try cursor.varint()
                    guard count <= UInt64(data.count) else { throw AccountUsageError.incompatibleFormat }
                    value = .bytes(try cursor.bytes(Int(count)))
                case 5:
                    let bytes = try cursor.bytes(4)
                    let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
                    value = .float(Double(Float(bitPattern: bits)))
                default: throw AccountUsageError.incompatibleFormat
                }
                fields[field, default: []].append(value)
            }
        }
        func validate(_ schema: Schema) throws {
            let children: [UInt64: Schema]
            let integers: Set<UInt64>
            let floats: Set<UInt64>
            let repeated: Set<UInt64>
            switch schema {
            case .config:
                children = [2: .cent, 3: .cent, 4: .timestamp, 5: .timestamp,
                            6: .history, 7: .product, 8: .period, 12: .cent]
                integers = [11, 13]; floats = [1]; repeated = [6, 7]
            case .period:
                children = [2: .timestamp, 3: .timestamp]; integers = [1]; floats = []; repeated = []
            case .history:
                children = [1: .cycle, 2: .cent, 3: .period]; integers = []; floats = []; repeated = []
            case .product:
                children = [:]; integers = [1]; floats = [2]; repeated = []
            case .cent:
                children = [:]; integers = [1]; floats = []; repeated = []
            case .timestamp, .cycle:
                children = [:]; integers = [1, 2]; floats = []; repeated = []
            }
            for (field, values) in fields {
                let known = children[field] != nil || integers.contains(field) || floats.contains(field)
                guard !known || repeated.contains(field) || values.count == 1 else {
                    throw AccountUsageError.incompatibleFormat
                }
                for value in values {
                    if let child = children[field] {
                        guard case let .bytes(data) = value else { throw AccountUsageError.incompatibleFormat }
                        try Message(data).validate(child)
                    } else if integers.contains(field) {
                        guard case .integer = value else { throw AccountUsageError.incompatibleFormat }
                    } else if floats.contains(field) {
                        guard case .float = value else { throw AccountUsageError.incompatibleFormat }
                    }
                }
            }
        }
        func single(_ field: UInt64) throws -> Value? {
            guard let values = fields[field] else { return nil }
            guard values.count == 1 else { throw AccountUsageError.incompatibleFormat }
            return values[0]
        }
        func requiredBytes(_ field: UInt64) throws -> Data {
            guard case let .bytes(data) = try single(field) else { throw AccountUsageError.incompatibleFormat }
            return data
        }
        func integer(_ field: UInt64) throws -> UInt64? {
            guard let value = try single(field) else { return nil }
            guard case let .integer(number) = value else { throw AccountUsageError.incompatibleFormat }
            return number
        }
        func float(_ field: UInt64) throws -> Double? {
            guard let value = try single(field) else { return nil }
            guard case let .float(number) = value else { throw AccountUsageError.incompatibleFormat }
            return number
        }
    }

    private struct Cursor {
        let data: [UInt8]
        var index = 0
        init(_ data: Data) { self.data = Array(data) }
        var atEnd: Bool { index == data.count }
        mutating func byte() throws -> UInt8 {
            guard index < data.count else { throw AccountUsageError.incompatibleFormat }
            defer { index += 1 }
            return data[index]
        }
        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - index else { throw AccountUsageError.incompatibleFormat }
            defer { index += count }
            return Data(data[index..<index + count])
        }
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for offset in 0..<10 {
                let next = try byte()
                guard offset < 9 || next <= 1 else { throw AccountUsageError.incompatibleFormat }
                value |= UInt64(next & 0x7f) << (offset * 7)
                if next & 0x80 == 0 { return value }
            }
            throw AccountUsageError.incompatibleFormat
        }
    }
}
