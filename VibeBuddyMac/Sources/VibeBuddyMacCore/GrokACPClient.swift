import Darwin
import Foundation

/// One newline-delimited JSON-RPC exchange with `grok agent --no-leader stdio`.
///
/// The Grok CLI speaks the Agent Client Protocol, whose extension methods carry
/// a leading underscore on the wire (`_x.ai/billing`); the unprefixed name is
/// answered with "Method not found". Requests are pipelined, so `initialize`
/// and the extension call cost one round trip, and the child is torn down as
/// soon as the awaited response arrives.
final class GrokACPClient: @unchecked Sendable {
    /// `params` is raw JSON so the request line can be written verbatim. A
    /// serializer would escape the `/` in `_x.ai/billing`, and the agent looks
    /// methods up literally, so the escaped form is an unknown method.
    struct Request: Sendable {
        var id: Int
        var method: String
        var params: String = "{}"

        var line: Data {
            Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#.utf8) + [0x0A]
        }
    }

    static let initializeRequest = Request(
        id: 1,
        method: "initialize",
        params: #"""
        {"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false}}
        """#
    )

    static let billingRequest = Request(id: 2, method: "_x.ai/billing")

    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    /// Requests termination from any thread. The blocking worker stays the sole
    /// owner of the pipes and of the final reap.
    func cancel() {
        lock.lock()
        isCancelled = true
        let process = process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    var cancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    /// Blocking: spawns the child, writes every request, and returns the raw
    /// response line whose `id` matches `responseID`.
    func exchange(
        executableURL: URL,
        arguments: [String],
        requests: [Request],
        responseID: Int,
        timeout: TimeInterval
    ) throws -> Data {
        guard timeout > 0 else { throw AccountUsageError.timedOut }
        let deadline = Date().addingTimeInterval(timeout)

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AccountUsageError.providerUnavailable
        }

        lock.lock()
        self.process = process
        let cancelledBeforeInstall = isCancelled
        lock.unlock()
        defer { teardown(process: process, input: input, output: output) }
        if cancelledBeforeInstall { throw CancellationError() }

        let inputDescriptor = input.fileHandleForWriting.fileDescriptor
        _ = Darwin.fcntl(inputDescriptor, F_SETNOSIGPIPE, 1)
        for request in requests {
            try write(request, to: inputDescriptor)
        }

        return try readResponse(
            id: responseID,
            from: output.fileHandleForReading.fileDescriptor,
            deadline: deadline
        )
    }

    private func write(_ request: Request, to descriptor: Int32) throws {
        try request.line.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: written), bytes.count - written)
                if count > 0 {
                    written += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw AccountUsageError.providerUnavailable
            }
        }
    }

    private func readResponse(id: Int, from descriptor: Int32, deadline: Date) throws -> Data {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let responseID = (object["id"] as? NSNumber)?.intValue,
                      responseID == id else { continue }
                return line
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AccountUsageError.timedOut }
            var descriptors = [pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)]
            let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)))
            let pollResult = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), max(1, milliseconds))
            }
            if pollResult == 0 { throw AccountUsageError.timedOut }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw AccountUsageError.unknown
            }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                if cancellationRequested { throw CancellationError() }
                throw AccountUsageError.providerUnavailable
            }
            buffer.append(bytes, count: count)
        }
    }

    /// Closing stdin is the agent's normal shutdown signal; TERM and then KILL
    /// bound how long a stuck child can outlive the request.
    private func teardown(process: Process, input: Pipe, output: Pipe) {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        let graceDeadline = ContinuousClock.now + .milliseconds(200)
        while process.isRunning, ContinuousClock.now < graceDeadline {
            Darwin.usleep(5_000)
        }
        if process.isRunning { process.terminate() }
        let terminationDeadline = ContinuousClock.now + .milliseconds(200)
        while process.isRunning, ContinuousClock.now < terminationDeadline {
            Darwin.usleep(5_000)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        lock.lock()
        self.process = nil
        lock.unlock()
    }
}
