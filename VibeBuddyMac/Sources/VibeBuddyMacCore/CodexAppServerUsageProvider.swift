import Darwin
import Foundation

public enum CodexUsageResponseDecoder {
    public static func decode(
        rateLimitsResponse: Data,
        usageResponse: Data,
        fetchedAt: Date
    ) throws -> CodexUsageSnapshot {
        do {
            let rateEnvelope = try JSONDecoder().decode(RateLimitsEnvelope.self, from: rateLimitsResponse)
            if let error = rateEnvelope.error { throw CodexUsageError.classify(message: error.message) }
            guard let result = rateEnvelope.result else { throw CodexUsageError.incompatibleFormat }

            let usageEnvelope = try JSONDecoder().decode(UsageEnvelope.self, from: usageResponse)
            if let error = usageEnvelope.error { throw CodexUsageError.classify(message: error.message) }
            guard let usage = usageEnvelope.result else { throw CodexUsageError.incompatibleFormat }

            let limits = result.rateLimitsByLimitId?["codex"]
                ?? result.rateLimitsByLimitId?.values.first(where: { $0.primary != nil || $0.secondary != nil })
                ?? result.rateLimits
            return CodexUsageSnapshot(
                planType: limits.planType,
                primary: limits.primary?.model(kind: .primary),
                secondary: limits.secondary?.model(kind: .secondary),
                lifetimeTokens: usage.summary.lifetimeTokens,
                latestDailyTokens: usage.dailyUsageBuckets?.max(by: { $0.startDate < $1.startDate })?.tokens,
                fetchedAt: fetchedAt
            )
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.incompatibleFormat
        }
    }
}

public final class CodexAppServerUsageProvider: CodexUsageProviding, @unchecked Sendable {
    private let executableURL: URL?
    private let arguments: [String]
    private let timeout: TimeInterval
    private let afterProcessInstall: (@Sendable () -> Void)?
    private let signalProcess: @Sendable (pid_t, Int32) -> Int32

    public init(
        executableURL: URL? = nil,
        arguments: [String] = ["app-server", "--stdio"],
        timeout: TimeInterval = 5
    ) {
        self.executableURL = executableURL ?? Self.resolveCodexExecutable()
        self.arguments = arguments
        self.timeout = timeout
        afterProcessInstall = nil
        signalProcess = { Darwin.kill($0, $1) }
    }

    init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        afterProcessInstall: @escaping @Sendable () -> Void,
        signalProcess: @escaping @Sendable (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.afterProcessInstall = afterProcessInstall
        self.signalProcess = signalProcess
    }

    public func fetch() async throws -> CodexUsageSnapshot {
        try Task.checkCancellation()
        guard let executableURL else { throw CodexUsageError.codexUnavailable }
        let arguments = arguments
        let timeout = timeout
        let afterProcessInstall = afterProcessInstall
        let lifecycle = CodexAppServerProcessLifecycle(signalProcess: signalProcess)
        return try await withTaskCancellationHandler {
            do {
                let snapshot = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result {
                            try Self.fetchBlocking(
                                executableURL: executableURL,
                                arguments: arguments,
                                timeout: timeout,
                                lifecycle: lifecycle,
                                afterProcessInstall: afterProcessInstall
                            )
                        })
                    }
                }
                try Task.checkCancellation()
                return snapshot
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            lifecycle.cancel()
        }
    }

    public static func resolveCodexExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let fixed = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"]
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/codex" }
        return (fixed + fromPath)
            .first(where: fileManager.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    private static func fetchBlocking(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        lifecycle: CodexAppServerProcessLifecycle,
        afterProcessInstall: (@Sendable () -> Void)?
    ) throws -> CodexUsageSnapshot {
        guard timeout > 0 else { throw CodexUsageError.timedOut }
        let child = try spawn(executableURL: executableURL, arguments: arguments)
        let shouldContinue = lifecycle.install(
            processID: child.processID,
            input: child.input,
            output: child.output
        )
        defer { lifecycle.teardown() }
        afterProcessInstall?()
        guard shouldContinue, !lifecycle.cancellationRequested else {
            throw CancellationError()
        }

        let client = LineRPCClient(
            input: child.input,
            output: child.output,
            cancellationDescriptor: lifecycle.cancellationDescriptor,
            deadline: Date().addingTimeInterval(timeout)
        )
        try client.send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "vibebuddy", "version": "0.1"],
                "capabilities": [:],
            ],
        ])
        let initialized = try client.response(id: 1)
        try throwRPCErrorIfPresent(in: initialized)

        try client.send(["jsonrpc": "2.0", "method": "initialized"])
        try client.send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"])
        let rateLimits = try client.response(id: 2)
        try client.send(["jsonrpc": "2.0", "id": 3, "method": "account/usage/read"])
        let usage = try client.response(id: 3)

        return try CodexUsageResponseDecoder.decode(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            fetchedAt: Date()
        )
    }

    private static func spawn(executableURL: URL, arguments: [String]) throws -> SpawnedCodexProcess {
        var stdinDescriptors = [Int32](repeating: -1, count: 2)
        var stdoutDescriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&stdinDescriptors) == 0 else { throw CodexUsageError.codexUnavailable }
        guard Darwin.pipe(&stdoutDescriptors) == 0 else {
            closeIfOpen(stdinDescriptors[0])
            closeIfOpen(stdinDescriptors[1])
            throw CodexUsageError.codexUnavailable
        }
        let nullDescriptor = Darwin.open("/dev/null", O_WRONLY)
        guard nullDescriptor >= 0 else {
            closeIfOpen(stdinDescriptors[0])
            closeIfOpen(stdinDescriptors[1])
            closeIfOpen(stdoutDescriptors[0])
            closeIfOpen(stdoutDescriptors[1])
            throw CodexUsageError.codexUnavailable
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closeIfOpen(stdinDescriptors[0])
            closeIfOpen(stdinDescriptors[1])
            closeIfOpen(stdoutDescriptors[0])
            closeIfOpen(stdoutDescriptors[1])
            closeIfOpen(nullDescriptor)
            throw CodexUsageError.codexUnavailable
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            closeIfOpen(stdinDescriptors[0])
            closeIfOpen(stdinDescriptors[1])
            closeIfOpen(stdoutDescriptors[0])
            closeIfOpen(stdoutDescriptors[1])
            closeIfOpen(nullDescriptor)
            throw CodexUsageError.codexUnavailable
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        var signalMask = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGPIPE)
        sigaddset(&defaultSignals, SIGQUIT)
        sigemptyset(&signalMask)
        let attributeResults = [
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            posix_spawnattr_setsigmask(&attributes, &signalMask),
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
            ),
        ]
        guard attributeResults.allSatisfy({ $0 == 0 }) else {
            closeIfOpen(stdinDescriptors[0])
            closeIfOpen(stdinDescriptors[1])
            closeIfOpen(stdoutDescriptors[0])
            closeIfOpen(stdoutDescriptors[1])
            closeIfOpen(nullDescriptor)
            throw CodexUsageError.codexUnavailable
        }

        let actionResults = [
            posix_spawn_file_actions_adddup2(&actions, stdinDescriptors[0], STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stdoutDescriptors[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, nullDescriptor, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdinDescriptors[0]),
            posix_spawn_file_actions_addclose(&actions, stdinDescriptors[1]),
            posix_spawn_file_actions_addclose(&actions, stdoutDescriptors[0]),
            posix_spawn_file_actions_addclose(&actions, stdoutDescriptors[1]),
            posix_spawn_file_actions_addclose(&actions, nullDescriptor),
        ]
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            closeIfOpen(stdinDescriptors[0])
            closeIfOpen(stdinDescriptors[1])
            closeIfOpen(stdoutDescriptors[0])
            closeIfOpen(stdoutDescriptors[1])
            closeIfOpen(nullDescriptor)
            throw CodexUsageError.codexUnavailable
        }

        let argumentStrings = [executableURL.path] + arguments
        var argumentPointers = argumentStrings.map { strdup($0) }
        argumentPointers.append(nil)
        defer {
            for pointer in argumentPointers.dropLast() {
                free(pointer)
            }
        }

        var processID = pid_t()
        let spawnResult = argumentPointers.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &processID,
                executableURL.path,
                &actions,
                &attributes,
                buffer.baseAddress,
                environ
            )
        }

        closeIfOpen(stdinDescriptors[0])
        closeIfOpen(stdoutDescriptors[1])
        closeIfOpen(nullDescriptor)
        guard spawnResult == 0 else {
            closeIfOpen(stdinDescriptors[1])
            closeIfOpen(stdoutDescriptors[0])
            throw CodexUsageError.codexUnavailable
        }

        _ = Darwin.fcntl(stdinDescriptors[1], F_SETNOSIGPIPE, 1)
        _ = Darwin.fcntl(stdinDescriptors[1], F_SETFD, FD_CLOEXEC)
        _ = Darwin.fcntl(stdoutDescriptors[0], F_SETFD, FD_CLOEXEC)
        return SpawnedCodexProcess(
            processID: processID,
            input: FileHandle(fileDescriptor: stdinDescriptors[1], closeOnDealloc: true),
            output: FileHandle(fileDescriptor: stdoutDescriptors[0], closeOnDealloc: true)
        )
    }

    private static func closeIfOpen(_ descriptor: Int32) {
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    private static func throwRPCErrorIfPresent(in data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return }
        let message = error["message"] as? String ?? "unknown"
        throw CodexUsageError.classify(message: message)
    }
}

private struct SpawnedCodexProcess {
    var processID: pid_t
    var input: FileHandle
    var output: FileHandle
}

/// Cancellation only signals the worker and requests process termination.
/// The blocking RPC worker remains the sole owner of FileHandle teardown and
/// wait/reap, so no other thread can close a descriptor while it is being read.
private final class CodexAppServerProcessLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationPipe = Pipe()
    private let signalProcess: @Sendable (pid_t, Int32) -> Int32
    private var processID: pid_t?
    private var input: FileHandle?
    private var output: FileHandle?
    private var isCancelled = false
    private var didRequestTermination = false
    private var acceptsCancellationSignals = true
    private var didReap = false

    init(signalProcess: @escaping @Sendable (pid_t, Int32) -> Int32) {
        self.signalProcess = signalProcess
        _ = Darwin.fcntl(cancellationPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = Darwin.fcntl(cancellationPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
    }

    var cancellationDescriptor: Int32 {
        cancellationPipe.fileHandleForReading.fileDescriptor
    }

    var cancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func install(processID: pid_t, input: FileHandle, output: FileHandle) -> Bool {
        lock.lock()
        self.processID = processID
        self.input = input
        self.output = output
        let shouldContinue = !isCancelled
        if !shouldContinue { sendTerminationIfNeededLocked(to: processID) }
        lock.unlock()
        return shouldContinue
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        if acceptsCancellationSignals, !didReap, let processID {
            sendTerminationIfNeededLocked(to: processID)
        }
        lock.unlock()
        // Wake the RPC reader only after TERM has completed and the state says
        // exactly that. The worker can never treat a pending signal as sent.
        try? cancellationPipe.fileHandleForWriting.write(contentsOf: Data([1]))
    }

    /// Called exactly once by the blocking worker after it has stopped using the
    /// RPC handles.
    func teardown() {
        lock.lock()
        guard !didReap, let processID else {
            lock.unlock()
            return
        }
        let input = input
        let output = output
        self.input = nil
        self.output = nil
        lock.unlock()

        try? input?.close()
        try? output?.close()

        lock.lock()
        sendTerminationIfNeededLocked(to: processID)
        lock.unlock()

        let graceDeadline = ContinuousClock.now + .milliseconds(200)
        while ContinuousClock.now < graceDeadline {
            lock.lock()
            let exited = reapIfExitedLocked(processID: processID)
            lock.unlock()
            if exited { return }
            Darwin.usleep(10_000)
        }

        lock.lock()
        if reapIfExitedLocked(processID: processID) {
            lock.unlock()
            return
        }
        // Only this worker calls waitpid. A WNOHANG result of zero means the
        // child is still owned and unreaped, so its PID cannot have been reused.
        if acceptsCancellationSignals {
            _ = signalProcess(processID, SIGKILL)
        }
        acceptsCancellationSignals = false
        lock.unlock()
        reapBlocking(processID: processID)
    }

    /// Caller holds the lock. The completed flag is set only after the signal
    /// syscall returns; no blocking wait occurs under the lock.
    private func sendTerminationIfNeededLocked(to processID: pid_t) {
        guard acceptsCancellationSignals, !didRequestTermination, !didReap else { return }
        _ = signalProcess(processID, SIGTERM)
        didRequestTermination = true
    }

    /// The lock prevents cancellation from signaling between successful reap
    /// and publishing didReap.
    private func reapIfExitedLocked(processID: pid_t) -> Bool {
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(processID, &status, WNOHANG)
            if result == processID {
                markReapedLocked()
                return true
            }
            if result == 0 { return false }
            if result == -1, errno == EINTR { continue }
            if result == -1, errno == ECHILD {
                markReapedLocked()
                return true
            }
            // Unknown waitpid failure: stop all future raw signals rather than
            // risk targeting a PID whose ownership can no longer be proven.
            markReapedLocked()
            return true
        }
    }

    private func reapBlocking(processID: pid_t) {
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(processID, &status, 0)
            if result == processID || (result == -1 && errno == ECHILD) {
                lock.lock()
                markReapedLocked()
                lock.unlock()
                return
            }
            if result == -1, errno == EINTR { continue }
            lock.lock()
            markReapedLocked()
            lock.unlock()
            return
        }
    }

    private func markReapedLocked() {
        didReap = true
        acceptsCancellationSignals = false
        self.processID = nil
    }
}

private final class LineRPCClient {
    private let input: FileHandle
    private let output: FileHandle
    private let cancellationDescriptor: Int32
    private let deadline: Date
    private var buffer = Data()
    private var pending: [Int: Data] = [:]

    init(input: FileHandle, output: FileHandle, cancellationDescriptor: Int32, deadline: Date) {
        self.input = input
        self.output = output
        self.cancellationDescriptor = cancellationDescriptor
        self.deadline = deadline
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    func response(id: Int) throws -> Data {
        if let response = pending.removeValue(forKey: id) { return response }
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let responseID = object["id"] as? Int else { continue }
                if responseID == id { return line }
                pending[responseID] = line
            }
            try readMore()
        }
    }

    private func readMore() throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw CodexUsageError.timedOut }
        var descriptors = [
            pollfd(fd: output.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0),
            pollfd(fd: cancellationDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0),
        ]
        let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)))
        let pollResult = descriptors.withUnsafeMutableBufferPointer {
            Darwin.poll($0.baseAddress, nfds_t($0.count), max(1, milliseconds))
        }
        if pollResult == 0 { throw CodexUsageError.timedOut }
        if pollResult < 0 {
            if errno == EINTR { return }
            throw CodexUsageError.unknown
        }
        if descriptors[1].revents != 0 { throw CancellationError() }

        var bytes = [UInt8](repeating: 0, count: 8_192)
        let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
        guard count > 0 else { throw CodexUsageError.codexUnavailable }
        buffer.append(bytes, count: count)
    }
}

private struct RPCErrorDTO: Decodable {
    var message: String
}

private struct RateLimitsEnvelope: Decodable {
    var result: RateLimitsResultDTO?
    var error: RPCErrorDTO?
}

private struct RateLimitsResultDTO: Decodable {
    var rateLimits: RateLimitsDTO
    var rateLimitsByLimitId: [String: RateLimitsDTO]?
}

private struct RateLimitsDTO: Decodable {
    var planType: String?
    var primary: RateLimitWindowDTO?
    var secondary: RateLimitWindowDTO?
}

private struct RateLimitWindowDTO: Decodable {
    var usedPercent: Int
    var windowDurationMins: Int?
    var resetsAt: Int?

    func model(kind: CodexUsageWindowKind) -> CodexUsageWindow {
        CodexUsageWindow(
            kind: kind,
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMins,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private struct UsageEnvelope: Decodable {
    var result: UsageResultDTO?
    var error: RPCErrorDTO?
}

private struct UsageResultDTO: Decodable {
    var summary: UsageSummaryDTO
    var dailyUsageBuckets: [DailyUsageBucketDTO]?
}

private struct UsageSummaryDTO: Decodable {
    var lifetimeTokens: Int?
}

private struct DailyUsageBucketDTO: Decodable {
    var startDate: String
    var tokens: Int
}
