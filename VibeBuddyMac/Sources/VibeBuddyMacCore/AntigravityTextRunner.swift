import Foundation
import Darwin

/// Single bounded text inference. No shell, auth extraction, API fallback or task tools.
struct AntigravityTextRunner: Sendable {
    enum Failure: String, Sendable { case cancelled, expired, invalidResponse, network }
    struct Reply: Sendable {
        var text: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
        var thinkingTokens: Int?
        var failure: Failure?
    }
    struct Output: Sendable { var data: Data; var status: Int32; var failure: Failure? }
    typealias Runner = @Sendable (URL, [String], URL, [String: String], TimeInterval) async -> Output
    var run: Runner = { executable, arguments, directory, environment, timeout in
        await BoundedAntigravityProcess.run(executable, arguments, directory, environment, timeout)
    }
    static let agent = """
    ---
    name: vibebuddy-summary
    description: Pure text response using only explicitly supplied context.
    tools: []
    mainAgent: true
    subagent: false
    model: inherit
    commandExecutionPolicy: off
    mcpServers: []
    skills: []
    plugins: []
    ---
    You are a pure text inference component. Answer the supplied question directly. Use only the supplied context. Do not propose tool actions, discuss task completion, create plans, inspect files, or use tools. Return the requested answer once, without commentary about your process.
    """
    func generate(text: String, model: String = "gemini-3.8-flash-low", timeout: TimeInterval) async -> Reply {
        guard !Task.isCancelled else { return Reply(failure: .cancelled) }
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { return Reply(failure: .expired) }
        guard text.utf8.count <= 250_000, model == "gemini-3.8-flash-low" else { return Reply(failure: .invalidResponse) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibebuddy-gemini-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let agents = directory.appendingPathComponent(".agents/agents")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.agent.write(to: agents.appendingPathComponent("vibebuddy-summary.md"), atomically: true, encoding: .utf8)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let output = await run(URL(fileURLWithPath: home + "/.local/bin/agy"),
                ["--agent", "vibebuddy-summary", "--model", model, "--disable-slash-commands", "--sandbox",
                 "--print-timeout", "\(max(1, Int(timeout)))s", "--output-format", "json", "--print", text],
                directory, ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:" + home + "/.local/bin"], timeout)
            if let failure = output.failure { return Reply(failure: failure) }
            guard output.status == 0,
                  let root = try JSONSerialization.jsonObject(with: output.data) as? [String: Any],
                  root["status"] as? String == "SUCCESS", root["num_turns"] as? Int == 1,
                  let response = root["response"] as? String else { return Reply(failure: .invalidResponse) }
            let usage = root["usage"] as? [String: Any] ?? [:]
            func token(_ key: String) -> Int? { guard let n = usage[key] as? Int, n >= 0 else { return nil }; return n }
            return Reply(text: response, inputTokens: token("input_tokens"), outputTokens: token("output_tokens"),
                         totalTokens: token("total_tokens"), thinkingTokens: token("thinking_tokens"))
        } catch { return Reply(failure: .invalidResponse) }
    }
}

/// Owns only its child PID. Nonblocking pipes drain on one queue; retained stdout is capped.
/// Parent exit closes readers immediately, including when descendants inherit the pipes.
final class BoundedAntigravityProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var failure: AntigravityTextRunner.Failure?
    private var data = Data()
    private var started = false
    static func run(_ executable: URL, _ arguments: [String], _ directory: URL,
                    _ environment: [String: String], _ timeout: TimeInterval) async -> AntigravityTextRunner.Output {
        let owner = BoundedAntigravityProcess()
        return await withTaskCancellationHandler {
            await owner.start(executable, arguments, directory, environment, timeout)
        } onCancel: { owner.stop(.cancelled) }
    }
    private func stop(_ reason: AntigravityTextRunner.Failure) {
        lock.withLock {
            if failure == nil { failure = reason }
            if started && process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    private func start(_ executable: URL, _ arguments: [String], _ directory: URL,
                       _ environment: [String: String], _ timeout: TimeInterval) async -> AntigravityTextRunner.Output {
        await withCheckedContinuation { continuation in
            let stdout = Pipe(), stderr = Pipe()
            let queue = DispatchQueue(label: "vibebuddy.agy.pipes")
            process.executableURL = executable; process.arguments = arguments
            process.currentDirectoryURL = directory; process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout; process.standardError = stderr
            let handles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
            let sources = handles.map { handle in
                _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK)
                return DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
            }
            @Sendable func drain(_ handle: FileHandle, retain: Bool) {
                var buffer = [UInt8](repeating: 0, count: 8192)
                // Finite drain: a producer continuously writing must not starve termination.
                for _ in 0..<32 {
                    let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                    guard count > 0 else { return }
                    if retain {
                        let overflow = self.lock.withLock {
                            guard self.data.count + count <= 131_072 else { return true }
                            self.data.append(contentsOf: buffer.prefix(count)); return false
                        }
                        if overflow { self.stop(.invalidResponse); return }
                    }
                }
            }
            for index in handles.indices {
                let handle = handles[index]
                sources[index].setEventHandler { drain(handle, retain: index == 0) }
                sources[index].setCancelHandler { try? handle.close() }
                sources[index].resume()
            }
            process.terminationHandler = { [self] child in
                queue.async {
                    drain(handles[0], retain: true); drain(handles[1], retain: false)
                    sources.forEach { $0.cancel() }
                    let output = self.lock.withLock {
                        self.started = false
                        return AntigravityTextRunner.Output(data: self.data, status: child.terminationStatus, failure: self.failure)
                    }
                    self.process.terminationHandler = nil
                    continuation.resume(returning: output)
                }
            }
            do {
                try lock.withLock {
                    if failure != nil { throw CancellationError() }
                    try process.run(); started = true
                }
            } catch {
                process.terminationHandler = nil
                sources.forEach { $0.cancel() }
                continuation.resume(returning: .init(data: Data(), status: -1, failure: lock.withLock { failure ?? .network }))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in self?.stop(.expired) }
        }
    }
}
