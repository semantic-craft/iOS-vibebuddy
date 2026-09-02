import Darwin
import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Codex usage adapter")
struct CodexUsageTests {
    private let now = Date(timeIntervalSince1970: 1_788_314_400)

    @Test("official app-server responses map quota windows and token usage")
    func responseDecoding() throws {
        let rateLimits = Data(#"""
        {
          "jsonrpc":"2.0","id":2,"result":{
            "accountId":"must-not-be-retained",
            "rateLimits":{
              "planType":"pro",
              "primary":{"usedPercent":72,"windowDurationMins":300,"resetsAt":1788318000},
              "secondary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1788912000}
            }
          }
        }
        """#.utf8)
        let usage = Data(#"""
        {
          "jsonrpc":"2.0","id":3,"result":{
            "summary":{"lifetimeTokens":1234567},
            "dailyUsageBuckets":[
              {"startDate":"2026-09-01","tokens":12000},
              {"startDate":"2026-09-02","tokens":34000}
            ]
          }
        }
        """#.utf8)

        let snapshot = try CodexUsageResponseDecoder.decode(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            fetchedAt: now
        )

        #expect(snapshot.planType == "pro")
        #expect(snapshot.primary?.usedPercent == 72)
        #expect(snapshot.primary?.windowDurationMinutes == 300)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_788_318_000))
        #expect(snapshot.secondary?.usedPercent == 41)
        #expect(snapshot.lifetimeTokens == 1_234_567)
        #expect(snapshot.latestDailyTokens == 34_000)
        #expect(snapshot.fetchedAt == now)
    }

    @Test("a changed response shape is unavailable instead of becoming zero usage")
    func formatChange() {
        let malformed = Data(#"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300}}}}"#.utf8)
        let usage = Data(#"{"jsonrpc":"2.0","id":3,"result":{"summary":{}}}"#.utf8)

        #expect(throws: CodexUsageError.incompatibleFormat) {
            try CodexUsageResponseDecoder.decode(
                rateLimitsResponse: malformed,
                usageResponse: usage,
                fetchedAt: now
            )
        }
    }

    @Test("successful refresh is cached as the last known good value")
    func successfulRefreshCaches() async {
        let snapshot = sampleSnapshot(percent: 55)
        let provider = ScriptedUsageProvider([.success(snapshot)])
        let cache = MemoryUsageCache()
        let collector = CodexUsageCollector(
            provider: provider,
            cache: cache,
            refreshInterval: 600,
            baseBackoff: 10,
            maxBackoff: 40,
            enabled: true
        )

        let state = await collector.refresh(now: now)

        #expect(state.snapshot?.primary?.usedPercent == 55)
        #expect(state.snapshot?.fetchedAt == now)
        #expect(!state.isStale)
        #expect(state.unavailableReason == nil)
        #expect(await cache.value()?.primary?.usedPercent == 55)
    }

    @Test("offline refresh preserves the cached value and marks it stale")
    func lastKnownGoodOnFailure() async {
        let cache = MemoryUsageCache(sampleSnapshot(percent: 61))
        let provider = ScriptedUsageProvider([.failure(.offline)])
        let collector = CodexUsageCollector(
            provider: provider,
            cache: cache,
            refreshInterval: 600,
            baseBackoff: 10,
            maxBackoff: 40,
            enabled: true
        )

        let cached = await collector.bootstrap(now: now)
        #expect(cached.snapshot?.primary?.usedPercent == 61)
        #expect(cached.isStale)

        let failed = await collector.refresh(now: now)
        #expect(failed.snapshot?.primary?.usedPercent == 61)
        #expect(failed.isStale)
        #expect(failed.unavailableReason == .offline)
        #expect(failed.nextRefreshAt == now.addingTimeInterval(10))
    }

    @Test("disabled collection never invokes the provider and hides cached data")
    func disabledDoesNoWork() async {
        let provider = ScriptedUsageProvider([.success(sampleSnapshot(percent: 80))])
        let cache = MemoryUsageCache(sampleSnapshot(percent: 61))
        let collector = CodexUsageCollector(provider: provider, cache: cache, enabled: false)

        let bootstrapped = await collector.bootstrap(now: now)
        let refreshed = await collector.refresh(now: now)

        #expect(!bootstrapped.collectionEnabled)
        #expect(bootstrapped.snapshot == nil)
        #expect(refreshed.unavailableReason == .collectionDisabled)
        #expect(await provider.callCount() == 0)
        #expect(await cache.loadCount() == 0)
    }

    @Test("a stale refresh cannot overwrite a rapid off-on cycle")
    func staleRefreshCannotOverwriteReenabledCollector() async {
        let provider = RacingUsageProvider(
            delayed: sampleSnapshot(percent: 99),
            immediate: sampleSnapshot(percent: 22)
        )
        let cache = MemoryUsageCache()
        let collector = CodexUsageCollector(
            provider: provider,
            cache: cache,
            refreshInterval: 600,
            enabled: true
        )

        let staleRefresh = Task { await collector.refresh(now: now) }
        await provider.waitUntilDelayedFetchStarts()
        _ = await collector.setEnabled(false, now: now)
        _ = await collector.setEnabled(true, now: now.addingTimeInterval(1))
        let current = await collector.refresh(
            now: now.addingTimeInterval(1),
            ignoringBackoff: true
        )
        await provider.completeDelayedFetch()
        _ = await staleRefresh.value
        let final = await collector.refresh(now: now.addingTimeInterval(2))

        #expect(current.snapshot?.primary?.usedPercent == 22)
        #expect(final.snapshot?.primary?.usedPercent == 22)
        #expect(await cache.value()?.primary?.usedPercent == 22)
    }

    @Test("exponential backoff suppresses refresh work until the retry date")
    func backoff() async {
        let provider = ScriptedUsageProvider([
            .failure(.rateLimited),
            .failure(.rateLimited),
            .success(sampleSnapshot(percent: 33)),
        ])
        let collector = CodexUsageCollector(
            provider: provider,
            cache: MemoryUsageCache(),
            refreshInterval: 600,
            baseBackoff: 10,
            maxBackoff: 40,
            enabled: true
        )

        let first = await collector.refresh(now: now)
        _ = await collector.refresh(now: now.addingTimeInterval(9))
        let second = await collector.refresh(now: now.addingTimeInterval(10))
        _ = await collector.refresh(now: now.addingTimeInterval(29))
        let recovered = await collector.refresh(now: now.addingTimeInterval(30))

        #expect(first.nextRefreshAt == now.addingTimeInterval(10))
        #expect(second.nextRefreshAt == now.addingTimeInterval(30))
        #expect(recovered.snapshot?.primary?.usedPercent == 33)
        #expect(!recovered.isStale)
        #expect(await provider.callCount() == 3)
    }

    @Test("app-server timeout and cancellation both reap their child process")
    func processCleanup() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-codex-process-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timeoutPIDFile = directory.appendingPathComponent("timeout.pid")
        let timeoutProvider = sleepingProvider(pidFile: timeoutPIDFile, timeout: 0.1)
        let started = ContinuousClock.now

        do {
            _ = try await timeoutProvider.fetch()
            Issue.record("Expected a timeout")
        } catch let error as CodexUsageError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(ContinuousClock.now - started < .seconds(1))
        await expectProcessExited(pidFile: timeoutPIDFile)

        let cancellationPIDFile = directory.appendingPathComponent("cancellation.pid")
        let barrier = ProcessInstallBarrier()
        let signalGate = ProcessSignalGate()
        let cancellationProvider = CodexAppServerUsageProvider(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "echo $$ > \"$1\"; exec sleep 5",
                "vibebuddy-test", cancellationPIDFile.path,
            ],
            timeout: 5,
            afterProcessInstall: { barrier.blockWorker() },
            signalProcess: { signalGate.send(processID: $0, signal: $1) }
        )
        let fetch = Task { try await cancellationProvider.fetch() }
        await barrier.waitUntilInstalled()
        let cancellationPID = await waitForPID(in: cancellationPIDFile)
        #expect(cancellationPID != nil)
        let cancellationStarted = ContinuousClock.now
        let cancellationRequest = Task { fetch.cancel() }
        await signalGate.waitUntilTerminationStarts()
        barrier.releaseWorker()
        try? await Task.sleep(for: .milliseconds(300))
        if let cancellationPID {
            #expect(Darwin.kill(cancellationPID, 0) == 0)
        }
        signalGate.allowTermination()
        await cancellationRequest.value
        do {
            _ = try await fetch.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(ContinuousClock.now - cancellationStarted < .seconds(1))
        await expectProcessExited(pidFile: cancellationPIDFile)
        #expect(signalGate.sentSignals() == [SIGTERM])

        let ignoredPIDFile = directory.appendingPathComponent("ignored-term.pid")
        let ignoredSignals = ProcessSignalGate(gateFirstTermination: false)
        let ignoredProvider = CodexAppServerUsageProvider(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "trap '' TERM; echo $$ > \"$1\"; exec sleep 5",
                "vibebuddy-test", ignoredPIDFile.path,
            ],
            timeout: 0.1,
            afterProcessInstall: {},
            signalProcess: { ignoredSignals.send(processID: $0, signal: $1) }
        )
        let ignoredStarted = ContinuousClock.now
        do {
            _ = try await ignoredProvider.fetch()
            Issue.record("Expected a timeout")
        } catch let error as CodexUsageError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(ContinuousClock.now - ignoredStarted < .seconds(1))
        await expectProcessExited(pidFile: ignoredPIDFile)
        #expect(ignoredSignals.sentSignals() == [SIGTERM, SIGKILL])
    }

    @Test("alerts persist per window and quiet mode consumes a crossing")
    func thresholdAlerts() {
        var monitor = CodexUsageAlertMonitor()
        let below = CodexUsageState.available(sampleSnapshot(percent: 89), nextRefreshAt: nil)
        let fresh = CodexUsageState.available(sampleSnapshot(percent: 90), nextRefreshAt: nil)
        let stale = CodexUsageState.stale(
            sampleSnapshot(percent: 96),
            reason: .offline,
            lastAttemptAt: now,
            nextRefreshAt: now.addingTimeInterval(10)
        )

        #expect(monitor.newlyCrossed(in: below, thresholdPercent: 90).isEmpty)
        #expect(monitor.newlyCrossed(in: fresh, thresholdPercent: 90).map(\.usedPercent) == [90])
        #expect(monitor.newlyCrossed(in: fresh, thresholdPercent: 90).isEmpty)
        #expect(monitor.newlyCrossed(in: stale, thresholdPercent: 90).isEmpty)
        #expect(monitor.newlyCrossed(in: below, thresholdPercent: 90).isEmpty)
        #expect(monitor.newlyCrossed(in: fresh, thresholdPercent: 90).isEmpty)

        var restarted = CodexUsageAlertMonitor(alertedWindowKeys: monitor.alertedWindowKeys)
        #expect(restarted.newlyCrossed(in: fresh, thresholdPercent: 90).isEmpty)

        var resetSnapshot = sampleSnapshot(percent: 89)
        resetSnapshot.primary?.resetsAt = now.addingTimeInterval(7200)
        let reset = CodexUsageState.available(resetSnapshot, nextRefreshAt: nil)
        #expect(restarted.newlyCrossed(in: reset, thresholdPercent: 90).isEmpty)
        resetSnapshot.primary?.usedPercent = 91
        let crossedDuringQuiet = CodexUsageState.available(resetSnapshot, nextRefreshAt: nil)
        #expect(restarted.newlyCrossed(
            in: crossedDuringQuiet,
            thresholdPercent: 90,
            notificationsSuppressed: true
        ).isEmpty)
        resetSnapshot.primary?.usedPercent = 95
        #expect(restarted.newlyCrossed(
            in: .available(resetSnapshot, nextRefreshAt: nil),
            thresholdPercent: 90
        ).isEmpty)
    }

    @Test("effective quiet includes manual and scheduled settings")
    func effectiveQuietSettings() throws {
        let suiteName = "CodexUsageTests.quiet.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "quietMode")
        #expect(NotificationQuietMode.isEffective(defaults: defaults, now: now))

        defaults.set(false, forKey: "quietMode")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let hour = calendar.component(.hour, from: now)
        let hours = QuietHours(enabled: true, startHour: hour, endHour: (hour + 1) % 24)
        defaults.set(try JSONEncoder().encode(hours), forKey: "quietHours")
        #expect(NotificationQuietMode.isEffective(defaults: defaults, now: now, calendar: calendar))
    }

    @Test("cache files are owner-only")
    func cachePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-codex-cache-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("usage.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CodexUsageFileCache(fileURL: file)

        try await cache.save(sampleSnapshot(percent: 40))

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
    }

    @Test("usage failures cannot mutate session progress")
    func progressIsolation() async {
        var reducer = SessionReducer()
        reducer.apply(HookEvent(
            kind: .userPromptSubmit,
            sessionID: "working",
            agent: .codex,
            cwd: "/tmp/project",
            timestamp: now
        ))
        let before = reducer.sessions["working"]
        let collector = CodexUsageCollector(
            provider: ScriptedUsageProvider([.failure(.notLoggedIn)]),
            cache: MemoryUsageCache(),
            enabled: true
        )

        _ = await collector.refresh(now: now)

        #expect(reducer.sessions["working"] == before)
        #expect(reducer.sessions["working"]?.status == .working)
    }

    private func sampleSnapshot(percent: Int) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            planType: "pro",
            primary: CodexUsageWindow(
                kind: .primary,
                usedPercent: percent,
                windowDurationMinutes: 300,
                resetsAt: now.addingTimeInterval(3600)
            ),
            secondary: nil,
            lifetimeTokens: 1_000_000,
            latestDailyTokens: 25_000,
            fetchedAt: now.addingTimeInterval(-60)
        )
    }

    private func sleepingProvider(pidFile: URL, timeout: TimeInterval) -> CodexAppServerUsageProvider {
        CodexAppServerUsageProvider(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$ > \"$1\"; exec sleep 5", "vibebuddy-test", pidFile.path],
            timeout: timeout
        )
    }

    private func waitForPID(in file: URL) async -> Int32? {
        for _ in 0..<100 {
            if let pid = (try? String(contentsOf: file, encoding: .utf8))
                .flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func expectProcessExited(pidFile: URL) async {
        let pid = await waitForPID(in: pidFile)
        #expect(pid != nil)
        if let pid {
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }
}

private actor ScriptedUsageProvider: CodexUsageProviding {
    private var results: [Result<CodexUsageSnapshot, CodexUsageError>]
    private var calls = 0

    init(_ results: [Result<CodexUsageSnapshot, CodexUsageError>]) {
        self.results = results
    }

    func fetch() async throws -> CodexUsageSnapshot {
        calls += 1
        guard !results.isEmpty else { throw CodexUsageError.unknown }
        return try results.removeFirst().get()
    }

    func callCount() -> Int { calls }
}

private actor RacingUsageProvider: CodexUsageProviding {
    private let delayed: CodexUsageSnapshot
    private let immediate: CodexUsageSnapshot
    private var calls = 0
    private var delayedContinuation: CheckedContinuation<CodexUsageSnapshot, Never>?

    init(delayed: CodexUsageSnapshot, immediate: CodexUsageSnapshot) {
        self.delayed = delayed
        self.immediate = immediate
    }

    func fetch() async throws -> CodexUsageSnapshot {
        calls += 1
        guard calls == 1 else { return immediate }
        return await withCheckedContinuation { continuation in
            delayedContinuation = continuation
        }
    }

    func waitUntilDelayedFetchStarts() async {
        while delayedContinuation == nil {
            await Task.yield()
        }
    }

    func completeDelayedFetch() {
        delayedContinuation?.resume(returning: delayed)
        delayedContinuation = nil
    }
}

private final class ProcessInstallBarrier: @unchecked Sendable {
    private let installed = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)

    func blockWorker() {
        installed.signal()
        proceed.wait()
    }

    func waitUntilInstalled() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.installed.wait()
                continuation.resume()
            }
        }
    }

    func releaseWorker() {
        proceed.signal()
    }
}

private final class ProcessSignalGate: @unchecked Sendable {
    private let lock = NSLock()
    private let terminationStarted = DispatchSemaphore(value: 0)
    private let terminationAllowed = DispatchSemaphore(value: 0)
    private let gateFirstTermination: Bool
    private var didGateTermination = false
    private var signals: [Int32] = []

    init(gateFirstTermination: Bool = true) {
        self.gateFirstTermination = gateFirstTermination
    }

    func send(processID: pid_t, signal: Int32) -> Int32 {
        lock.lock()
        let shouldGate = gateFirstTermination && signal == SIGTERM && !didGateTermination
        if shouldGate { didGateTermination = true }
        lock.unlock()

        if shouldGate {
            terminationStarted.signal()
            terminationAllowed.wait()
        }
        lock.lock()
        signals.append(signal)
        lock.unlock()
        return Darwin.kill(processID, signal)
    }

    func waitUntilTerminationStarts() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.terminationStarted.wait()
                continuation.resume()
            }
        }
    }

    func allowTermination() {
        terminationAllowed.signal()
    }

    func sentSignals() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return signals
    }
}

private actor MemoryUsageCache: CodexUsageCaching {
    private var snapshot: CodexUsageSnapshot?
    private var loads = 0

    init(_ snapshot: CodexUsageSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() async -> CodexUsageSnapshot? {
        loads += 1
        return snapshot
    }

    func save(_ snapshot: CodexUsageSnapshot) async throws {
        self.snapshot = snapshot
    }

    func value() -> CodexUsageSnapshot? { snapshot }
    func loadCount() -> Int { loads }
}
