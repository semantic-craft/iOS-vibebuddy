import Foundation
import Testing
@testable import VibeBuddyMacCore

/// `hooks/cursor-followup.sh` against a daemon that accepts and never answers
/// (or answers half a response): it must still try both requests, print
/// nothing, and end on its own network budget, which fits inside the `stop`
/// timeout the installer writes.
/// Ported from the retired `hooks/test_install_agent_hooks.py`.
@Suite("Cursor stop hook against a hung daemon", .serialized)
struct CursorFollowupTimeoutTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Accepts connections on 127.0.0.1, records each request line, and keeps
    /// every socket open without replying until `stop()`.
    final class HungServer: @unchecked Sendable {
        let port: Int
        private let listener: Int32
        private let partialFollowup: Bool
        private let lock = NSLock()
        private var paths: [String] = []
        private var clients: [Int32] = []

        init(partialFollowup: Bool) throws {
            self.partialFollowup = partialFollowup
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
            }
            guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw CocoaError(.featureUnsupported) }
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            port = Int(UInt16(bigEndian: address.sin_port))
            listener = fd
            Thread { [self] in acceptLoop() }.start()
        }

        var requested: [String] { lock.withLock { paths } }

        private func acceptLoop() {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                lock.withLock { clients.append(client) }
                Thread { [self] in serve(client) }.start()
            }
        }

        private func serve(_ client: Int32) {
            var buffer = [UInt8](repeating: 0, count: 65536)
            var received = Data()
            while !received.contains(Data("\r\n\r\n".utf8)) {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { return }
                received.append(buffer, count: count)
            }
            let line = String(decoding: received.prefix { $0 != 0x0D }, as: UTF8.self)
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            lock.withLock { paths.append(path) }
            if partialFollowup, path == "/cursor-followup" {
                let body = #"{"followup_message":"must-not-reach-cursor"}"#
                let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count + 100)\r\n\r\n"
                _ = (head + body).withCString { write(client, $0, strlen($0)) }
            }
            // Never finish the response.
        }

        func stop() {
            lock.withLock {
                for client in clients { close(client) }
                clients = []
            }
            shutdown(listener, SHUT_RDWR)
            close(listener)
        }
    }

    @Test("fails open, silently, within the installed stop timeout", arguments: [false, true])
    func hungDaemon(partial: Bool) async throws {
        // The deadline is whatever the installer writes for `stop`.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vb-cursor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(environment: HookInstallerEnvironment(home: home, claudeVersion: { nil }),
                                      scriptSource: Self.repo.appendingPathComponent("hooks"))
        let cursor = CursorHooks(paths: installer.paths, context: installer.context(manifest: HookManifest()))
        let stop = try #require(cursor.desired(approval: false).first { $0.0 == "stop" }?.1.first)
        guard case .number(let timeout)? = stop["timeout"], let deadline = TimeInterval(timeout) else {
            Issue.record("stop entry has no numeric timeout"); return
        }
        #expect(deadline == 5)

        // The script's own network budget is what keeps it inside the
        // deadline: its requests run one after another, each capped by
        // `--max-time`, with the rest of the 5 s left for shell and JSON.
        // Checked on the script itself, so a loaded host cannot fail it.
        let script = try String(contentsOf: Self.repo.appendingPathComponent("hooks/cursor-followup.sh"), encoding: .utf8)
        let budgets = script.split(separator: "\n")
            .filter { $0.contains("curl ") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .map { line -> TimeInterval? in
                guard let range = line.range(of: #"--max-time [0-9.]+"#, options: .regularExpression) else { return nil }
                return TimeInterval(line[range].dropFirst("--max-time ".count))
            }
        #expect(budgets.count == 2 && budgets.allSatisfy { $0 != nil }, "every curl carries --max-time: \(budgets)")
        let budget = budgets.compactMap { $0 }.reduce(0, +)
        #expect(budget <= deadline - 2, "network budget \(budget)s leaves under 2 s of a \(deadline)s deadline")

        let server = try HungServer(partialFollowup: partial)
        defer { server.stop() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("hooks/cursor-followup.sh").path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path,
                               "VIBEBUDDY_PORT": String(server.port),
                               "VIBEBUDDY_TOKEN": "disposable-test-token", "VIBEBUDDY_TOKEN_FILE": "/dev/null"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Not `waitUntilExit()`: it parks a cooperative thread in a run loop
        // that can miss the exit wake-up, which hung a full `swift test` run.
        let (exited, exit) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exit.finish() }
        let started = Date()
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"stop","conversation_id":"timeout-test"}"#.utf8))
        try input.fileHandleForWriting.close()
        // Liveness bound only: a script without its caps would hang here.
        while process.isRunning && Date().timeIntervalSince(started) < 30 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = Date().timeIntervalSince(started)
        if process.isRunning { process.terminate() }
        for await _ in exited {}
        // The hung daemon holds both requests to their caps, so the script
        // ended on its own budget, not on luck or an early error.
        #expect(elapsed >= budget, "took \(elapsed)s against a \(budget)s budget")
        #expect(elapsed < 30, "hung: \(elapsed)s")
        #expect(process.terminationStatus == 0)
        #expect(output.fileHandleForReading.availableData.isEmpty)
        #expect(errors.fileHandleForReading.availableData.isEmpty)
        // The server thread records a request when it reads it, which a
        // loaded host may do after the script has already given up.
        let recorded = Date().addingTimeInterval(30)
        while !(server.requested.contains { $0.hasPrefix("/hook?") } && server.requested.contains("/cursor-followup")),
              Date() < recorded {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(server.requested.contains { $0.hasPrefix("/hook?") })
        #expect(server.requested.contains("/cursor-followup"))
    }
}
