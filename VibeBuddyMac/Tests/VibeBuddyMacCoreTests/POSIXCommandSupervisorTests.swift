import Darwin
import Foundation
import Testing
@testable import VibeBuddyMacCore

/// The supervisor owns every child process the app shells out to, so its
/// guarantees are tested here rather than through whichever provider happens
/// to spawn one today.
@Suite("POSIX command supervisor")
struct POSIXCommandSupervisorTests {

    @Test("a child that outruns the output limit is stopped and reported",
          .timeLimit(.minutes(1)))
    func outputLimit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("overflow.pid")
        let supervisor = try POSIXCommandSupervisor()

        let run = Task.detached {
            try supervisor.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", "echo $$ > \"$1\"; (yes o | head -c 700000) & (yes e | head -c 700000 >&2) & wait; exec sleep 30",
                    "vibebuddy-test", pidFile.path,
                ],
                environment: [:],
                timeout: 5,
                outputLimit: 1_048_576
            )
        }
        do {
            _ = try await run.value
            Issue.record("Expected the output limit to be enforced")
        } catch let error as POSIXCommandError {
            guard case .outputLimitExceeded = error else {
                Issue.record("Unexpected supervisor error: \(error)")
                return
            }
        }
        await expectProcessExited(pidFile: pidFile)
    }

    /// A child can hand its stdout to a grandchild and exit. Both the
    /// grandchild that inherited the pipe and one that redirected away from it
    /// must still be reaped once the command's own output is complete and
    /// valid — otherwise a refresh every few minutes leaks a process each time.
    @Test("a descendant left behind by a successful command is still reaped",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func descendantCleanup(detached: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("descendant.pid")
        let supervisor = try POSIXCommandSupervisor()
        let redirect = detached ? " </dev/null >/dev/null 2>&1" : ""

        let result = try await Task.detached {
            try supervisor.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", "(trap '' TERM; exec sleep 30\(redirect)) & echo $! > \"$1\"; exec /usr/bin/printf '%s' \"$2\"",
                    "vibebuddy-test", pidFile.path, "done",
                ],
                environment: [:],
                timeout: 5,
                outputLimit: 1_048_576
            )
        }.value

        #expect(result.exitedSuccessfully)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "done")
        await expectProcessExited(pidFile: pidFile)
    }

    /// Pipe() leaves its descriptors inheritable. A child that picks up some
    /// other reader's write end keeps that reader from ever seeing EOF, so the
    /// supervisor's children must get nothing beyond stdin, stdout and stderr.
    /// The probe is an external command: a builtin's redirection makes the
    /// shell back up fds 0 and 2 onto 10 and 11 first, a false "open".
    @Test("a child does not inherit the parent's other descriptors",
          .timeLimit(.minutes(1)))
    func descriptorsNotInherited() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(Darwin.pipe(&descriptors) == 0)
        defer { descriptors.forEach { _ = Darwin.close($0) } }
        let supervisor = try POSIXCommandSupervisor()

        let result = try await Task.detached { [descriptors] in
            try supervisor.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", "for fd in \"$@\"; do if /usr/bin/true <&\"$fd\" 2>/dev/null; then echo \"$fd open\"; fi; done; echo checked",
                    "vibebuddy-test", String(descriptors[0]), String(descriptors[1]),
                ],
                environment: [:],
                timeout: 5,
                outputLimit: 1_048_576
            )
        }.value

        #expect(result.exitedSuccessfully)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "checked\n")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-supervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForPID(in file: URL) async -> Int32? {
        for _ in 0..<500 {
            if let pid = (try? String(contentsOf: file, encoding: .utf8))
                .flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// A killed process dies asynchronously, so poll for its reaping rather
    /// than sampling once — under a loaded parallel run the signal has often
    /// not landed yet.
    private func expectProcessExited(pidFile: URL) async {
        guard let pid = await waitForPID(in: pidFile) else {
            Issue.record("The child never reported its process id")
            return
        }
        for _ in 0..<500 {
            if Darwin.kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Process \(pid) was still running")
    }
}
