import Foundation
import VibeBuddyKit

/// One `agent acp` process, spoken to over its stdio: JSON-RPC 2.0, one
/// message per line (cursor.com/docs/cli/acp, agentclientprotocol.com).
///
/// The Codex app-server client owns a socket; this one owns a child process
/// and two pipes. Both do the same three things — send requests and await the
/// matching response, hand notifications and server-initiated requests to
/// whoever registered for them, and fail every pending request the moment the
/// far side goes away — so the monitor built on top can be read next to
/// `CodexAppServerMonitor` without translation.
///
/// Reading and writing take `FileHandle`s rather than a `Process`, so a test can
/// stand in a scripted agent on a pair of pipes and the same code runs against
/// it. `spawn` is the production constructor.
public final class CursorACPClient: @unchecked Sendable {
    public enum ClientError: Error, Equatable {
        /// The process ended, or `close()` was called, with the request outstanding.
        case closed
        /// The agent answered with a JSON-RPC error.
        case rpc(code: Int, message: String)
        /// The agent answered something that is not a JSON-RPC response.
        case malformed
        case timeout
    }

    /// The agent's process, when this client spawned one. Nil on a test pair.
    public let process: Process?
    private let reader: FileHandle
    private let writer: FileHandle
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()
    private var closed = false
    private var started = false

    /// A `session/update` or any other id-less message from the agent.
    public var onNotification: (@Sendable (String, [String: Any]?) -> Void)?
    /// A request the agent expects an answer to (`session/request_permission`,
    /// `cursor/ask_question`, …). The handler must eventually call `respond`.
    public var onRequest: (@Sendable (JSONRPCID, String, [String: Any]?) -> Void)?
    /// The far side is gone: EOF on stdout, or the process exited.
    public var onClose: (@Sendable () -> Void)?

    public init(reading: FileHandle, writing: FileHandle, process: Process? = nil) {
        self.reader = reading
        self.writer = writing
        self.process = process
    }

    /// `agent acp` in `cwd`, with any extra arguments in front of `acp` (a
    /// `-w` worktree flag, for instance). stderr is discarded: the CLI logs
    /// there and nothing in it is protocol.
    public static func spawn(executable: URL, cwd: String?, leadingArguments: [String] = [],
                             environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CursorACPClient {
        let process = Process()
        process.executableURL = executable
        process.arguments = leadingArguments + ["acp"]
        if let cwd, !cwd.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = environment
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let client = CursorACPClient(reading: stdout.fileHandleForReading,
                                     writing: stdin.fileHandleForWriting, process: process)
        process.terminationHandler = { [weak client] _ in client?.close() }
        try process.run()
        return client
    }

    /// Begin reading. Handlers registered after this may miss early messages,
    /// so set them first.
    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.close()
                return
            }
            self.consume(data)
        }
    }

    /// Send a request and await its response. `timeout` nil waits as long as
    /// the agent takes — the right choice for `session/prompt`, which returns
    /// only when the whole turn is over.
    public func request(_ method: String, params: [String: Any] = [:],
                        timeout: Duration? = .seconds(60)) async throws -> [String: Any] {
        let id = allocateID()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: ClientError.closed)
                return
            }
            pending[id] = continuation
            lock.unlock()
            let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            guard send(message) else {
                if let waiter = takePending(id) { waiter.resume(throwing: ClientError.closed) }
                return
            }
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    if let waiter = self?.takePending(id) { waiter.resume(throwing: ClientError.timeout) }
                }
            }
        }
    }

    public func notify(_ method: String, params: [String: Any] = [:]) {
        _ = send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    public func respond(id: JSONRPCID, result: Any) {
        _ = send(["jsonrpc": "2.0", "id": id.json, "result": result])
    }

    public func respondError(id: JSONRPCID, code: Int, message: String) {
        _ = send(["jsonrpc": "2.0", "id": id.json, "error": ["code": code, "message": message]])
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// Fail every outstanding request, stop reading, end the process. Idempotent.
    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let waiters = pending
        pending = [:]
        lock.unlock()
        reader.readabilityHandler = nil
        try? writer.close()
        if let process, process.isRunning { process.terminate() }
        for waiter in waiters.values { waiter.resume(throwing: ClientError.closed) }
        onClose?()
    }

    // MARK: - Wire

    private func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private func takePending(_ id: Int) -> CheckedContinuation<[String: Any], Error>? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func send(_ json: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(json),
              var data = try? JSONSerialization.data(withJSONObject: json) else { return false }
        data.append(0x0A)
        lock.lock()
        let open = !closed
        lock.unlock()
        guard open else { return false }
        do {
            try writer.write(contentsOf: data)
            return true
        } catch {
            close()
            return false
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty { dispatch(line) }
    }

    private func dispatch(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let method = message["method"] as? String
        let id = JSONRPCID(message["id"])
        if let method {
            if let id {
                onRequest?(id, method, message["params"] as? [String: Any])
            } else {
                onNotification?(method, message["params"] as? [String: Any])
            }
            return
        }
        // A response to one of ours.
        guard case .number(let number)? = id, let waiter = takePending(number) else { return }
        if let error = message["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? -1
            let text = (error["message"] as? String) ?? "error"
            waiter.resume(throwing: ClientError.rpc(code: code, message: text))
        } else if let result = message["result"] as? [String: Any] {
            waiter.resume(returning: result)
        } else if message["result"] is NSNull || message.keys.contains("result") {
            // `session/load` answers `null`; an empty object is the same fact.
            waiter.resume(returning: [:])
        } else {
            waiter.resume(throwing: ClientError.malformed)
        }
    }
}
