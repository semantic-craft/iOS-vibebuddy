import Darwin
import Foundation

/// A JSON-RPC 2.0 client for the Codex app-server daemon, spoken over a
/// WebSocket on its unix control socket (`~/.codex/app-server-control/
/// app-server-control.sock`). This is the transport every Codex client
/// (Desktop, the CLI TUI, `codex agents`, `codex queue`) shares, so a
/// connection here sees the same threads they do.
///
/// Deliberately small: a hand-rolled RFC 6455 client (handshake, masked text
/// frames, ping/pong, close) on a raw socket, because no packaged client
/// speaks WebSocket over a unix domain socket. Requests are awaited by id;
/// everything else the server sends — notifications and server-initiated
/// requests — is delivered raw on `messages`, in arrival order.
///
/// The client never answers a server-initiated request. Approval and
/// user-input requests are left to the client that owns the thread (Desktop,
/// the TUI); ticket 03 decides how vibebuddy joins that flow.
public final class CodexAppServerClient: @unchecked Sendable {
    public enum ClientError: Error, Equatable, Sendable {
        case socketUnavailable(String)
        case handshakeRejected(String)
        case closed
        case timeout(String)
        case rpc(code: Int, message: String)
        case malformed
    }

    public static let defaultSocketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/app-server-control/app-server-control.sock").path

    public let socketPath: String
    /// Notifications and server-initiated requests, as the raw JSON of each
    /// message. Finishes when the connection closes.
    public let messages: AsyncStream<Data>

    private let messageSink: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var reader: Thread?
    private var isClosed = false

    public init(socketPath: String = CodexAppServerClient.defaultSocketPath) {
        self.socketPath = socketPath
        var sink: AsyncStream<Data>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { sink = $0 }
        messageSink = sink
    }

    deinit { close() }

    // MARK: - Connection

    /// Connect and complete the WebSocket upgrade. Throws when the socket file
    /// is missing (no daemon), refuses the connection, or answers anything but
    /// `101 Switching Protocols`.
    public func connect() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socketUnavailable("socket(): \(errnoText())") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw ClientError.socketUnavailable("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard connected == 0 else {
            let reason = errnoText()
            Darwin.close(fd)
            throw ClientError.socketUnavailable("connect(): \(reason)")
        }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard Self.writeAll(fd, Data(request.utf8)) else {
            Darwin.close(fd)
            throw ClientError.handshakeRejected("write failed: \(errnoText())")
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else {
                Darwin.close(fd)
                throw ClientError.handshakeRejected(n == 0 ? "closed during handshake" : errnoText())
            }
            buffer.append(chunk, count: n)
            if buffer.count > 64 * 1024 {
                Darwin.close(fd)
                throw ClientError.handshakeRejected("oversized handshake response")
            }
        }
        let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))!
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        guard head.hasPrefix("HTTP/1.1 101") else {
            Darwin.close(fd)
            throw ClientError.handshakeRejected(head.split(separator: "\r\n").first.map(String.init) ?? "no status")
        }
        // A daemon that starts to stream frames inside the handshake read is
        // legal; keep the tail and let the reader continue from it.
        let leftover = Data(buffer[headerEnd.upperBound...])
        // The reader owns the receive side from here; disable its timeout so
        // an idle daemon does not read as a dropped connection.
        var forever = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
        lock.lock()
        descriptor = fd
        isClosed = false
        lock.unlock()
        let thread = Thread { [weak self] in self?.readLoop(fd: fd, leftover: leftover) }
        thread.name = "com.vibebuddy.codex-app-server-reader"
        thread.qualityOfService = .utility
        reader = thread
        thread.start()
    }

    /// Close the socket. Pending requests fail with `.closed`, `messages` ends.
    public func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        let wasClosed = isClosed
        isClosed = true
        let waiting = pending
        pending = [:]
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        for (_, continuation) in waiting { continuation.resume(throwing: ClientError.closed) }
        if !wasClosed { messageSink.finish() }
    }

    // MARK: - RPC

    /// Send a request and await its `result`. A JSON-RPC `error` throws `.rpc`.
    public func request(_ method: String, params: [String: Any] = [:],
                        timeout: Duration = .seconds(15)) async throws -> [String: Any] {
        let id = try allocateRequestID()
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            register(id, continuation)
            guard send(json: message) else {
                _ = takePending(id)?.resume(throwing: ClientError.closed)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.takePending(id)?.resume(throwing: ClientError.timeout(method))
            }
        }
    }

    /// Send a notification (no id, no reply).
    public func notify(_ method: String, params: [String: Any]? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        _ = send(json: message)
    }

    // MARK: - Wire

    private func allocateRequestID() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed, descriptor >= 0 else { throw ClientError.closed }
        let id = nextID
        nextID += 1
        return id
    }

    private func register(_ id: Int, _ continuation: CheckedContinuation<[String: Any], Error>) {
        lock.lock(); defer { lock.unlock() }
        pending[id] = continuation
    }

    private func takePending(_ id: Int) -> CheckedContinuation<[String: Any], Error>? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func send(json: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json) else { return false }
        return send(frame: Self.frame(opcode: 0x1, payload: data))
    }

    private func send(frame: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed, descriptor >= 0 else { return false }
        return Self.writeAll(descriptor, frame)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// A client→server frame: FIN set, masked, with the 7/16/64-bit length form.
    static func frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 {
            out.append(0x80 | UInt8(n))
        } else if n < 65_536 {
            out.append(0x80 | 126)
            out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF))
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((n >> shift) & 0xFF)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        out.append(contentsOf: mask)
        var masked = Data(capacity: n)
        for (index, byte) in payload.enumerated() { masked.append(byte ^ mask[index & 3]) }
        out.append(masked)
        return out
    }

    private func readLoop(fd: Int32, leftover: Data) {
        var buffer = leftover
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var textFragments = Data()
        while true {
            while let parsed = Self.parseFrame(buffer) {
                buffer.removeSubrange(0..<parsed.consumed)
                switch parsed.opcode {
                case 0x1, 0x0:
                    textFragments.append(parsed.payload)
                    if parsed.fin {
                        dispatch(textFragments)
                        textFragments = Data()
                    }
                case 0x2:
                    break   // binary frames are not part of the app-server protocol
                case 0x8:
                    close()
                    return
                case 0x9:
                    _ = send(frame: Self.frame(opcode: 0xA, payload: parsed.payload))
                default:
                    break
                }
            }
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else {
                close()
                return
            }
            buffer.append(chunk, count: n)
        }
    }

    struct Frame { let fin: Bool; let opcode: UInt8; let payload: Data; let consumed: Int }

    /// One complete server frame from the head of `data`, or nil when more
    /// bytes are needed. Server frames are unmasked; a masked one is tolerated.
    static func parseFrame(_ data: Data) -> Frame? {
        guard data.count >= 2 else { return nil }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        var length = Int(b1 & 0x7F)
        var offset = 2
        if length == 126 {
            guard data.count >= 4 else { return nil }
            length = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
            offset = 4
        } else if length == 127 {
            guard data.count >= 10 else { return nil }
            length = 0
            for i in 2..<10 { length = length << 8 | Int(data[data.startIndex + i]) }
            offset = 10
        }
        let masked = b1 & 0x80 != 0
        var mask: [UInt8] = []
        if masked {
            guard data.count >= offset + 4 else { return nil }
            mask = (0..<4).map { data[data.startIndex + offset + $0] }
            offset += 4
        }
        guard data.count >= offset + length else { return nil }
        var payload = Data(data[(data.startIndex + offset)..<(data.startIndex + offset + length)])
        if masked {
            for i in 0..<payload.count { payload[payload.startIndex + i] ^= mask[i & 3] }
        }
        return Frame(fin: b0 & 0x80 != 0, opcode: b0 & 0x0F, payload: payload, consumed: offset + length)
    }

    private func dispatch(_ text: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: text)) as? [String: Any] else { return }
        // A reply to one of ours: an `id` we are waiting on and no `method`.
        if object["method"] == nil, let id = Self.integer(object["id"]),
           let continuation = takePending(id) {
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: ClientError.rpc(
                    code: Self.integer(error["code"]) ?? -1,
                    message: error["message"] as? String ?? "unknown error"))
            } else if let result = object["result"] as? [String: Any] {
                continuation.resume(returning: result)
            } else {
                // `null` or a bare value: legal for a few methods, nothing to read.
                continuation.resume(returning: [:])
            }
            return
        }
        messageSink.yield(text)
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private func errnoText() -> String { String(cString: strerror(errno)) }
}
