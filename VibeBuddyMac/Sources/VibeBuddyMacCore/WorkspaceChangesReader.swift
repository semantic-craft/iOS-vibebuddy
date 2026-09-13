import Foundation
import VibeBuddyKit

/// Read-only Git subprocesses; arguments never go through a shell. No textconv
/// or external diff driver, and no fallback to another comparison scope.
public enum WorkspaceChangesReader {
    public static func read(cwd: String?, scope: ChangesScope, baseline: String?, file: String?, shared: Bool) -> WorkspaceChanges {
        let attribution = shared
            ? "Workspace changes · multiple sessions share this directory. Changes cannot be attributed to this task."
            : "Workspace changes · task ownership and pre-existing changes are not established. Includes user and other agent edits."
        var result = WorkspaceChanges(scope: scope, baseline: scope == .branch ? (baseline ?? "Not selected") : "HEAD",
                                      attribution: attribution)
        guard let cwd, cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd) else {
            result.unavailableReason = "No accessible local workspace for this session."; return result
        }
        guard let repository = run(cwd, ["rev-parse", "--show-toplevel"], cap: 8192), repository.code == 0 else {
            result.unavailableReason = "This directory is not an accessible Git repository."; return result
        }
        let root = repository.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var comparison: [String]
        switch scope {
        case .uncommitted: comparison = ["HEAD"]
        case .staged: comparison = ["--cached", "HEAD"]
        case .branch:
            guard let baseline, !baseline.isEmpty, baseline.count <= 200, !baseline.hasPrefix("-"),
                  let revision = run(root, ["rev-parse", "--verify", "--end-of-options", baseline + "^{commit}"], cap: 8192), revision.code == 0 else {
                result.unavailableReason = "Select an existing branch or commit as the baseline."; return result
            }
            let commit = revision.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let mergeBase = run(root, ["merge-base", commit, "HEAD"], cap: 8192), mergeBase.code == 0 else {
                result.unavailableReason = "No common baseline exists for this branch comparison."; return result
            }
            let base = mergeBase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            comparison = [base, "HEAD"]
            result.baseline = "\(baseline) · merge base \(base) → HEAD"
        }
        let prefix = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames"]
        guard let names = run(root, prefix + ["--name-only", "-z"] + comparison + ["--"], cap: 64_000), names.code == 0,
              let stat = run(root, prefix + ["--stat"] + comparison + ["--"], cap: 32_000), stat.code == 0 else {
            result.unavailableReason = "Git could not read the selected comparison (HEAD may not exist yet)."; return result
        }
        result.files = Array(names.text.split(separator: "\0").map(String.init).prefix(200))
        result.stat = stat.text
        if scope == .uncommitted {
            guard let untracked = run(root, ["ls-files", "--others", "--exclude-standard", "-z"], cap: 64_000), untracked.code == 0 else {
                result.unavailableReason = "Untracked files could not be checked; workspace cleanliness is unknown."; return result
            }
            result.untrackedFiles = Array(untracked.text.split(separator: "\0").map(String.init).prefix(200))
            result.truncated = untracked.truncated || untracked.text.split(separator: "\0").count > 200
        }
        result.truncated = result.truncated || names.truncated || stat.truncated || names.text.split(separator: "\0").count > 200
        if let file {
            guard result.files.contains(file) else { result.unavailableReason = "That file is not in this comparison. Refresh the file list."; return result }
            if let diff = run(root, prefix + ["--no-color"] + comparison + ["--", file], cap: 128_000), diff.code == 0 {
                result.diff = diff.text; result.truncated = result.truncated || diff.truncated
            } else { result.unavailableReason = "The selected file diff is unavailable." }
        }
        return result
    }

    private struct Output { let code: Int32; let text: String; let truncated: Bool }
    private static func run(_ cwd: String, _ arguments: [String], cap: Int) -> Output? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", cwd] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_PAGER"] = "cat"
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Drain concurrently, keeping a bounded prefix. A timeout bounds a
        // repository's pathological diff; excess bytes never accumulate.
        let collected = BoundedOutput(limit: cap)
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty { collected.append(chunk) }
            drained.signal()
        }
        if done.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            _ = drained.wait(timeout: .now() + 1)
            return nil
        }
        _ = drained.wait(timeout: .now() + 1)
        let (data, truncated) = collected.result()
        return Output(code: process.terminationStatus, text: String(decoding: data, as: UTF8.self), truncated: truncated)
    }
}
private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        data.append(chunk.prefix(remaining)); truncated = truncated || chunk.count > remaining
    }
    func result() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (data, truncated) }
}
