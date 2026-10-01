import Foundation

public struct CursorCloudStreamEvent: Sendable, Equatable {
    public let id: String?
    public let kind: String
    public let data: String
}

/// Backpressure is the awaited consumer; there is no unbounded event queue.
public protocol CursorCloudStreamTransport: Sendable {
    func consume(_ request: URLRequest,
                 receive: @escaping @Sendable (CursorCloudStreamEvent) async throws -> Void) async throws
}

public struct CursorCloudURLStreamTransport: CursorCloudStreamTransport {
    public init() {}
    public func consume(_ request: URLRequest,
                        receive: @escaping @Sendable (CursorCloudStreamEvent) async throws -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw CursorCloudError.transport }
        guard http.statusCode == 200 else {
            throw CursorCloudError.service(status: http.statusCode, code: nil)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
            throw CursorCloudError.undecodable
        }
        var parser = CursorCloudSSEParser()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let event = try parser.append(byte) { try await receive(event) }
        }
    }
}

/// SSE framing across arbitrary network chunks. A line/frame exceeding 64KiB
/// disconnects and leaves polling authoritative instead of growing indefinitely.
struct CursorCloudSSEParser {
    private var line: [UInt8] = []
    private var kind = "message"
    private var id: String?
    private var data: [String] = []
    private var size = 0
    private var afterCR = false
    mutating func append(_ byte: UInt8) throws -> CursorCloudStreamEvent? {
        if afterCR { afterCR = false; if byte == 10 { return nil } }
        if byte != 10 && byte != 13 {
            guard line.count + size < 65_536 else { throw CursorCloudError.undecodable }
            line.append(byte); return nil
        }
        afterCR = byte == 13
        guard let text = String(bytes: line, encoding: .utf8) else { throw CursorCloudError.undecodable }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            defer { kind = "message"; id = nil; data = []; size = 0 }
            guard !data.isEmpty else { return nil }
            return CursorCloudStreamEvent(id: id, kind: kind, data: data.joined(separator: "\n"))
        }
        size += text.utf8.count
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch parts[0] {
        case "event": kind = value
        case "id": if !value.contains("\0") { id = value }
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}
