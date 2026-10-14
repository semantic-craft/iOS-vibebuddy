import Foundation
import Darwin
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

struct GeminiCLITests {
    private func input() -> CompletionSummaryInput {
        let now = Date()
        return .init(sourceID: "synthetic", sessionID: "test", completionID: UUID().uuidString,
            title: "Example", finalText: "Local build passed; device checks are pending.", completedAt: now, observedAt: now)
    }
    private func config() -> CompletionSummaryConfiguration {
        .init(enabled: true, provider: .gemini, modelID: "gemini-3.8-flash", geminiTransport: .localCLI)
    }
    private var fixture: AntigravityTextRunner.Runner { { executable, arguments, cwd, environment, timeout in
        #expect(executable.path.hasSuffix("/.local/bin/agy"))
        #expect(Set(environment.keys) == ["HOME", "PATH"])
        #expect(arguments.contains("--sandbox"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(!arguments.contains("--mode"))
        #expect(!arguments.contains("--json-schema"))
        #expect(timeout > 0 && timeout <= 30)
        let agent = try? String(contentsOf: cwd.appendingPathComponent(".agents/agents/vibebuddy-summary.md"), encoding: .utf8)
        #expect(agent == AntigravityTextRunner.agent)
        return .init(data: Data(#"{"status":"SUCCESS","num_turns":1,"response":"Build passed; device checks remain pending.","usage":{"input_tokens":23,"output_tokens":8,"total_tokens":31}}"#.utf8), status: 0)
    } }

    @Test func newGeminiDefaultsToLocalAndPreservesExplicitAPIChoice() throws {
        let name = "local-gemini-default-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("gemini", forKey: VoiceSettings.summaryProviderKey)
        #expect(CompletionSummaryConfiguration.load(defaults: defaults).usesGeminiCLI)
        #expect(!CompletionSummaryConfiguration.load(defaults: defaults).requiresAPIKey)
        defaults.set("api", forKey: CompletionSummaryConfiguration.geminiTransportKey)
        #expect(!CompletionSummaryConfiguration.load(defaults: defaults).usesGeminiCLI)
        #expect(CompletionSummaryConfiguration.load(defaults: defaults).requiresAPIKey)
        #expect(!CompletionSummaryConfiguration(enabled: true, provider: .qwen, modelID: "qwen").usesGeminiCLI)
    }

    @Test func noticeAndPresentationUseLocalTransportWithoutReadingAPIKey() async {
        let service = CompletionSummaryService(key: { _ in Issue.record("CLI must not load API key"); return nil })
        await service.setCLIRunnerForTesting(fixture)
        let result = await service.generate(input(), configuration: config())
        #expect(result.failure == nil)
        #expect(result.text == "Build passed; device checks remain pending.")
        #expect(result.usage?.totalTokens == 31)
        let presentation = ContentPresentationService(key: { _ in Issue.record("CLI must not load API key"); return nil })
        await presentation.setCLIRunnerForTesting(fixture)
        #expect(await presentation.generate(input(), purpose: .speech, configuration: config()) == result.text)
        var api = config(); api.geminiTransport = .api
        #expect(api.presentationRevision != config().presentationRevision)
        #expect(api.requiresAPIKey)
    }

    @Test func cancellingOneSharedPresentationDoesNotCancelTheOtherOrPoisonCache() async throws {
        let presentation = ContentPresentationService(key: { _ in Issue.record("No API"); return nil })
        let fixture = self.fixture
        await presentation.setCLIRunnerForTesting { executable, args, cwd, env, timeout in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return .init(data: Data(), status: -1, failure: .cancelled) }
            return await fixture(executable, args, cwd, env, timeout)
        }
        let source = input(), configuration = config()
        let first = Task { await presentation.outcome(source, purpose: .speech, configuration: configuration) }
        try await Task.sleep(for: .milliseconds(30))
        let second = Task { await presentation.outcome(source, purpose: .speech, configuration: configuration) }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        #expect(await first.value == .failed(.cancelled))
        #expect(await second.value.text == "Build passed; device checks remain pending.")
        #expect(await presentation.outcome(source, purpose: .speech, configuration: configuration).text != nil)
    }

    @Test func newSubscriberDoesNotJoinCancelledGenerationStillUnwinding() async throws {
        let presentation = ContentPresentationService(key: { _ in nil })
        let fixture = self.fixture
        await presentation.setCLIRunnerForTesting { executable, args, cwd, env, timeout in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch {
                // Deliberately slow cancellation unwind exposes pending-generation races.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { continuation.resume() }
                }
                return .init(data: Data(), status: -1, failure: .cancelled)
            }
            return await fixture(executable, args, cwd, env, timeout)
        }
        let source = input(), configuration = config()
        let first = Task { await presentation.outcome(source, purpose: .speech, configuration: configuration) }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        try await Task.sleep(for: .milliseconds(30))
        let replacement = await presentation.outcome(source, purpose: .speech, configuration: configuration)
        #expect(replacement.text != nil)
        #expect(await first.value == .failed(.cancelled))
        #expect(await presentation.outcome(source, purpose: .speech, configuration: configuration).text != nil)
    }

    @Test func failedCLIHasNoAPIFallbackAndInvalidTextIsRejected() async {
        let service = CompletionSummaryService(key: { _ in Issue.record("No paid fallback"); return "not-used" })
        await service.setCLIRunnerForTesting { _, _, _, _, _ in .init(data: Data(), status: 1, failure: .network) }
        #expect(await service.generate(input(), configuration: config()).failure == .network)
        var cli = GeminiCLI()
        cli.run = { _, _, _, _, _ in
            .init(data: Data(#"{"status":"SUCCESS","num_turns":1,"response":"**Fabricated result**"}"#.utf8), status: 0)
        }
        #expect(await cli.generate(input: input(), configuration: config(), timeout: 1, purpose: .notice).text == nil)
    }

    @Test func processIsBoundedAndCancellationStopsItsOwnChild() async {
        let cwd = FileManager.default.temporaryDirectory
        let timed = await BoundedAntigravityProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], cwd, [:], 0.05)
        #expect(timed.failure == .expired)
        let flooded = await BoundedAntigravityProcess.run(URL(fileURLWithPath: "/usr/bin/yes"), [], cwd, [:], 2)
        #expect(flooded.failure == .invalidResponse)
        #expect(flooded.data.count <= 131_072)
        let task = Task { await BoundedAntigravityProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], cwd, [:], 10) }
        task.cancel()
        #expect(await task.value.failure == .cancelled)
    }

    @Test func cancellationAfterStartupStopsOnlyOwnedProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agy-cancel-proof-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started.pid")
        let control = Process()
        control.executableURL = URL(fileURLWithPath: "/bin/sleep")
        control.arguments = ["10"]
        try control.run()
        defer { if control.isRunning { control.terminate() }; control.waitUntilExit() }
        // Test fixture only. exec preserves the recorded child PID; production uses no shell.
        let task = Task { await BoundedAntigravityProcess.run(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "echo $$ > \"$1\"; exec /bin/sleep 10", "fixture", marker.path], directory, [:], 5) }
        defer { task.cancel() }
        var ownedPID: Int32?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: marker, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { ownedPID = pid; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(ownedPID)
        #expect(kill(pid, 0) == 0)
        #expect(pid != control.processIdentifier)
        task.cancel()
        #expect(await task.value.failure == .cancelled)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(control.isRunning)
    }

    @Test func parentExitDoesNotWaitForDescendantPipeEOF() async {
        // Synthetic fixture only: production never invokes a shell.
        let started = ContinuousClock.now
        let result = await BoundedAntigravityProcess.run(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "sleep 2 & printf done"], FileManager.default.temporaryDirectory, [:], 0.5)
        #expect(result.status == 0)
        #expect(result.failure == nil)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(String(decoding: result.data, as: UTF8.self) == "done")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_AGY_E2E"] == "1"))
    func realLocalGeminiSummaryService() async {
        let service = CompletionSummaryService(key: { _ in Issue.record("Local CLI must not load API secrets"); return nil })
        let result = await service.generate(input(), configuration: config())
        #expect(result.failure == nil)
        #expect(result.text?.isEmpty == false)
        await service.waitUntilIdle()
    }
}
