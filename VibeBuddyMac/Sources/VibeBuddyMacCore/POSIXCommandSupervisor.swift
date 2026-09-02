import Darwin
import Foundation

enum POSIXCommandError: Error {
    case spawnFailed
    case timedOut
    case outputLimitExceeded
    case waitFailed
}

struct POSIXCommandResult {
    var standardOutput: Data
    var standardError: Data
    var waitStatus: Int32

    var exitedSuccessfully: Bool { waitStatus == 0 }
}

/// Runs one child process under a single blocking owner. Cancellation only sets
/// a flag and wakes that owner; the worker alone signals the process group,
/// closes command descriptors, and reaps the root child.
final class POSIXCommandSupervisor: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var didWake = false
    private var cancellationDescriptors = [Int32](repeating: -1, count: 2)

    init() throws {
        guard Darwin.pipe(&cancellationDescriptors) == 0 else {
            throw POSIXCommandError.spawnFailed
        }
        do {
            for descriptor in cancellationDescriptors {
                try Self.configureNonBlocking(descriptor)
            }
        } catch {
            for index in cancellationDescriptors.indices {
                Self.closeIfOpen(&cancellationDescriptors[index])
            }
            throw error
        }
    }

    deinit {
        for descriptor in cancellationDescriptors where descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    func cancel() {
        let shouldWake = lock.withLock { () -> Bool in
            cancelled = true
            guard !didWake else { return false }
            didWake = true
            return true
        }
        guard shouldWake else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(cancellationDescriptors[1], &byte, 1)
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        outputLimit: Int
    ) throws -> POSIXCommandResult {
        guard timeout > 0 else { throw POSIXCommandError.timedOut }
        guard outputLimit > 0 else { throw POSIXCommandError.outputLimitExceeded }
        if isCancelled { throw CancellationError() }

        let child = try Self.spawn(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
        var standardOutput = Data()
        var standardError = Data()
        var remainingOutputBytes = outputLimit
        var stdoutDescriptor = child.standardOutput
        var stderrDescriptor = child.standardError
        var stdoutEOF = false
        var stderrEOF = false
        var didReap = false
        defer {
            Self.closeIfOpen(&stdoutDescriptor)
            Self.closeIfOpen(&stderrDescriptor)
            if !didReap {
                Self.terminateAndReap(
                    processID: child.processID,
                    stdoutDescriptor: &stdoutDescriptor,
                    stderrDescriptor: &stderrDescriptor,
                    standardOutput: &standardOutput,
                    standardError: &standardError,
                    remainingOutputBytes: &remainingOutputBytes,
                    deadline: Date().addingTimeInterval(0.2)
                )
            }
        }

        let finalDeadline = Date().addingTimeInterval(timeout)
        let shutdownAllowance = min(0.2, max(0.02, timeout * 0.2))
        let workDeadline = finalDeadline.addingTimeInterval(-shutdownAllowance)

        while true {
            if isCancelled {
                Self.terminateAndReap(
                    processID: child.processID,
                    stdoutDescriptor: &stdoutDescriptor,
                    stderrDescriptor: &stderrDescriptor,
                    standardOutput: &standardOutput,
                    standardError: &standardError,
                    remainingOutputBytes: &remainingOutputBytes,
                    deadline: min(finalDeadline, Date().addingTimeInterval(0.2))
                )
                didReap = true
                throw CancellationError()
            }

            let childExited = try Self.childHasExited(child.processID)
            try Self.drain(
                descriptor: &stdoutDescriptor,
                buffer: &standardOutput,
                reachedEOF: &stdoutEOF,
                remainingOutputBytes: &remainingOutputBytes
            )
            try Self.drain(
                descriptor: &stderrDescriptor,
                buffer: &standardError,
                reachedEOF: &stderrEOF,
                remainingOutputBytes: &remainingOutputBytes
            )

            if childExited {
                // The root remains unreaped, so its process-group identity
                // cannot be reused while we terminate every descendant. Pipe
                // EOF is not proof that the group is empty: a descendant can
                // redirect both streams and outlive the root.
                Self.terminateProcessGroup(
                    child.processID,
                    stdoutDescriptor: &stdoutDescriptor,
                    stderrDescriptor: &stderrDescriptor,
                    standardOutput: &standardOutput,
                    standardError: &standardError,
                    remainingOutputBytes: &remainingOutputBytes,
                    deadline: finalDeadline
                )
                let status = try Self.reap(child.processID)
                didReap = true
                return POSIXCommandResult(
                    standardOutput: standardOutput,
                    standardError: standardError,
                    waitStatus: status
                )
            }

            guard Date() < workDeadline else {
                Self.terminateAndReap(
                    processID: child.processID,
                    stdoutDescriptor: &stdoutDescriptor,
                    stderrDescriptor: &stderrDescriptor,
                    standardOutput: &standardOutput,
                    standardError: &standardError,
                    remainingOutputBytes: &remainingOutputBytes,
                    deadline: finalDeadline
                )
                didReap = true
                throw POSIXCommandError.timedOut
            }

            try pollForProgress(
                stdoutDescriptor: stdoutDescriptor,
                stderrDescriptor: stderrDescriptor,
                deadline: workDeadline
            )
        }
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    private func pollForProgress(
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32,
        deadline: Date
    ) throws {
        var descriptors: [pollfd] = []
        if stdoutDescriptor >= 0 {
            descriptors.append(pollfd(
                fd: stdoutDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            ))
        }
        if stderrDescriptor >= 0 {
            descriptors.append(pollfd(
                fd: stderrDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            ))
        }
        descriptors.append(pollfd(
            fd: cancellationDescriptors[0],
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        ))
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let milliseconds = Int32(max(1, min(50, remaining * 1_000)))
        let result = descriptors.withUnsafeMutableBufferPointer {
            Darwin.poll($0.baseAddress, nfds_t($0.count), milliseconds)
        }
        if result < 0, errno != EINTR { throw POSIXCommandError.waitFailed }
    }

    private static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> SpawnedCommand {
        var stdoutDescriptors = [Int32](repeating: -1, count: 2)
        var stderrDescriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&stdoutDescriptors) == 0 else { throw POSIXCommandError.spawnFailed }
        guard Darwin.pipe(&stderrDescriptors) == 0 else {
            closeIfOpen(&stdoutDescriptors[0])
            closeIfOpen(&stdoutDescriptors[1])
            throw POSIXCommandError.spawnFailed
        }
        do {
            try configureNonBlocking(stdoutDescriptors[0])
            try configureNonBlocking(stderrDescriptors[0])
        } catch {
            closeIfOpen(&stdoutDescriptors[0])
            closeIfOpen(&stdoutDescriptors[1])
            closeIfOpen(&stderrDescriptors[0])
            closeIfOpen(&stderrDescriptors[1])
            throw error
        }
        var nullDescriptor = Darwin.open("/dev/null", O_RDONLY)
        guard nullDescriptor >= 0 else {
            closeIfOpen(&stdoutDescriptors[0])
            closeIfOpen(&stdoutDescriptors[1])
            closeIfOpen(&stderrDescriptors[0])
            closeIfOpen(&stderrDescriptors[1])
            throw POSIXCommandError.spawnFailed
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closeIfOpen(&stdoutDescriptors[0])
            closeIfOpen(&stdoutDescriptors[1])
            closeIfOpen(&stderrDescriptors[0])
            closeIfOpen(&stderrDescriptors[1])
            closeIfOpen(&nullDescriptor)
            throw POSIXCommandError.spawnFailed
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            closeIfOpen(&stdoutDescriptors[0])
            closeIfOpen(&stdoutDescriptors[1])
            closeIfOpen(&stderrDescriptors[0])
            closeIfOpen(&stderrDescriptors[1])
            closeIfOpen(&nullDescriptor)
            throw POSIXCommandError.spawnFailed
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
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP)
            ),
        ]
        let actionResults = [
            posix_spawn_file_actions_adddup2(&actions, nullDescriptor, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stdoutDescriptors[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrDescriptors[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdoutDescriptors[0]),
            posix_spawn_file_actions_addclose(&actions, stdoutDescriptors[1]),
            posix_spawn_file_actions_addclose(&actions, stderrDescriptors[0]),
            posix_spawn_file_actions_addclose(&actions, stderrDescriptors[1]),
            posix_spawn_file_actions_addclose(&actions, nullDescriptor),
        ]
        guard attributeResults.allSatisfy({ $0 == 0 }),
              actionResults.allSatisfy({ $0 == 0 }) else {
            closeIfOpen(&stdoutDescriptors[0])
            closeIfOpen(&stdoutDescriptors[1])
            closeIfOpen(&stderrDescriptors[0])
            closeIfOpen(&stderrDescriptors[1])
            closeIfOpen(&nullDescriptor)
            throw POSIXCommandError.spawnFailed
        }

        let argumentStrings = [executableURL.path] + arguments
        var argumentPointers = argumentStrings.map { strdup($0) }
        argumentPointers.append(nil)
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        var environmentPointers = environmentStrings.map { strdup($0) }
        environmentPointers.append(nil)
        defer {
            for pointer in argumentPointers.dropLast() { free(pointer) }
            for pointer in environmentPointers.dropLast() { free(pointer) }
        }

        var processID = pid_t()
        let spawnResult = argumentPointers.withUnsafeMutableBufferPointer { argumentsBuffer in
            environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    executableURL.path,
                    &actions,
                    &attributes,
                    argumentsBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
        closeIfOpen(&stdoutDescriptors[1])
        closeIfOpen(&stderrDescriptors[1])
        closeIfOpen(&nullDescriptor)
        guard spawnResult == 0 else {
            closeIfOpen(&stdoutDescriptors[0])
            closeIfOpen(&stderrDescriptors[0])
            throw POSIXCommandError.spawnFailed
        }

        return SpawnedCommand(
            processID: processID,
            standardOutput: stdoutDescriptors[0],
            standardError: stderrDescriptors[0]
        )
    }

    private static func childHasExited(_ processID: pid_t) throws -> Bool {
        var info = siginfo_t()
        while true {
            let result = Darwin.waitid(P_PID, id_t(processID), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == 0 { return info.si_pid == processID }
            if errno == EINTR { continue }
            throw POSIXCommandError.waitFailed
        }
    }

    private static func drain(
        descriptor: inout Int32,
        buffer: inout Data,
        reachedEOF: inout Bool,
        remainingOutputBytes: inout Int
    ) throws {
        guard descriptor >= 0, !reachedEOF else { return }
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                guard count <= remainingOutputBytes else {
                    throw POSIXCommandError.outputLimitExceeded
                }
                buffer.append(bytes, count: count)
                remainingOutputBytes -= count
                continue
            }
            if count == 0 {
                reachedEOF = true
                closeIfOpen(&descriptor)
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            reachedEOF = true
            closeIfOpen(&descriptor)
            return
        }
    }

    private static func terminateProcessGroup(
        _ processID: pid_t,
        stdoutDescriptor: inout Int32,
        stderrDescriptor: inout Int32,
        standardOutput: inout Data,
        standardError: inout Data,
        remainingOutputBytes: inout Int,
        deadline: Date
    ) {
        _ = Darwin.kill(-processID, SIGTERM)
        let graceDeadline = min(deadline, Date().addingTimeInterval(0.2))
        while Date() < graceDeadline {
            var stdoutEOF = stdoutDescriptor < 0
            var stderrEOF = stderrDescriptor < 0
            try? drain(
                descriptor: &stdoutDescriptor,
                buffer: &standardOutput,
                reachedEOF: &stdoutEOF,
                remainingOutputBytes: &remainingOutputBytes
            )
            try? drain(
                descriptor: &stderrDescriptor,
                buffer: &standardError,
                reachedEOF: &stderrEOF,
                remainingOutputBytes: &remainingOutputBytes
            )
            Darwin.usleep(10_000)
        }
        _ = Darwin.kill(-processID, SIGKILL)
    }

    private static func terminateAndReap(
        processID: pid_t,
        stdoutDescriptor: inout Int32,
        stderrDescriptor: inout Int32,
        standardOutput: inout Data,
        standardError: inout Data,
        remainingOutputBytes: inout Int,
        deadline: Date
    ) {
        terminateProcessGroup(
            processID,
            stdoutDescriptor: &stdoutDescriptor,
            stderrDescriptor: &stderrDescriptor,
            standardOutput: &standardOutput,
            standardError: &standardError,
            remainingOutputBytes: &remainingOutputBytes,
            deadline: deadline
        )
        _ = try? reap(processID)
    }

    private static func reap(_ processID: pid_t) throws -> Int32 {
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(processID, &status, 0)
            if result == processID { return status }
            if result == -1, errno == EINTR { continue }
            throw POSIXCommandError.waitFailed
        }
    }

    private static func closeIfOpen(_ descriptor: inout Int32) {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private static func configureNonBlocking(_ descriptor: Int32) throws {
        guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw POSIXCommandError.spawnFailed
        }
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXCommandError.spawnFailed
        }
    }
}

private struct SpawnedCommand {
    var processID: pid_t
    var standardOutput: Int32
    var standardError: Int32
}
