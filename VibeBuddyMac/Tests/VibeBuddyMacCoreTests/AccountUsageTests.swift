import Darwin
import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Account usage adapters")
struct AccountUsageTests {
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

    @Test("official Claude usage output maps session and weekly windows")
    func claudeResponseDecoding() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let fetchedAt = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 2, hour: 12
        )))
        let output = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 9% used · resets Sep 2 at 6:39pm (Asia/Shanghai)
        Current week (all models): 15% used · resets Sep 5 at 7:59pm (Asia/Shanghai)
        Current week (Fable): 18% used · resets Sep 5 at 7:59pm (Asia/Shanghai)

        What's contributing to your limits usage?
        """
        let data = try JSONSerialization.data(withJSONObject: [
            "is_error": false,
            "result": output,
        ])

        let snapshot = try ClaudeUsageResponseDecoder.decode(
            data,
            fetchedAt: fetchedAt,
            calendar: calendar
        )

        #expect(snapshot.provider == .claude)
        #expect(snapshot.primary?.usedPercent == 9)
        #expect(snapshot.primary?.windowDurationMinutes == 300)
        #expect(snapshot.secondary?.usedPercent == 15)
        #expect(snapshot.secondary?.windowDurationMinutes == 10_080)
        #expect(snapshot.primary?.resetsAt == calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 2, hour: 18, minute: 39
        )))
        #expect(snapshot.secondary?.resetsAt == calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 19, minute: 59
        )))
    }

    @Test("a Claude window that resets on the hour prints no minutes and still parses")
    func claudeWholeHourReset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let fetchedAt = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 3, hour: 12
        )))
        // Recorded verbatim from `claude -p /usage --output-format json`: the CLI
        // writes "8pm", not "8:00pm", whenever a window happens to reset on the hour.
        let output = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 43% used · resets Sep 3 at 2:30pm (Asia/Shanghai)
        Current week (all models): 58% used · resets Sep 5 at 8pm (Asia/Shanghai)
        Current week (Fable): 58% used · resets Sep 5 at 8pm (Asia/Shanghai)

        What's contributing to your limits usage?
        """
        let data = try JSONSerialization.data(withJSONObject: [
            "is_error": false,
            "result": output,
        ])

        let snapshot = try ClaudeUsageResponseDecoder.decode(
            data, fetchedAt: fetchedAt, calendar: calendar)

        #expect(snapshot.secondary?.usedPercent == 58)
        #expect(snapshot.secondary?.resetsAt == calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 20
        )))
        #expect(snapshot.primary?.resetsAt == calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 3, hour: 14, minute: 30
        )))
    }

    @Test("provider percentages outside zero through one hundred are rejected")
    func percentageBounds() throws {
        let output = """
        Current session: 101% used · resets Sep 2 at 6:39pm (Asia/Shanghai)
        Current week (all models): 15% used · resets Sep 5 at 7:59pm (Asia/Shanghai)
        """
        let claudeData = try JSONSerialization.data(withJSONObject: [
            "is_error": false,
            "result": output,
        ])
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try ClaudeUsageResponseDecoder.decode(claudeData, fetchedAt: now)
        }

        let codexLimits = Data(#"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":-1,"windowDurationMins":300}}}}"#.utf8)
        let codexUsage = Data(#"{"jsonrpc":"2.0","id":3,"result":{"summary":{}}}"#.utf8)
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try CodexUsageResponseDecoder.decode(
                rateLimitsResponse: codexLimits,
                usageResponse: codexUsage,
                fetchedAt: now
            )
        }
    }

    @Test("Claude CLI timeout and cancellation reap their child process")
    func claudeProcessCleanup() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-claude-process-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let timeoutPIDFile = directory.appendingPathComponent("timeout.pid")
        let timeoutProvider = claudeSleepingProvider(pidFile: timeoutPIDFile, timeout: 0.1)
        do {
            _ = try await timeoutProvider.fetch()
            Issue.record("Expected a timeout")
        } catch let error as AccountUsageError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        await expectProcessExited(pidFile: timeoutPIDFile)

        let cancellationPIDFile = directory.appendingPathComponent("cancellation.pid")
        let cancellationProvider = claudeSleepingProvider(pidFile: cancellationPIDFile, timeout: 5)
        let fetch = Task { try await cancellationProvider.fetch() }
        #expect(await waitForPID(in: cancellationPIDFile) != nil)
        fetch.cancel()
        do {
            _ = try await fetch.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        await expectProcessExited(pidFile: cancellationPIDFile)

        let overflowPIDFile = directory.appendingPathComponent("overflow.pid")
        let overflowProvider = ClaudeCLIUsageProvider(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "echo $$ > \"$1\"; (yes o | head -c 700000) & (yes e | head -c 700000 >&2) & wait; exec sleep 5",
                "vibebuddy-test", overflowPIDFile.path,
            ],
            timeout: 2
        )
        let overflowStarted = ContinuousClock.now
        do {
            _ = try await overflowProvider.fetch()
            Issue.record("Expected the output limit to be enforced")
        } catch let error as AccountUsageError {
            #expect(error == .incompatibleFormat)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(ContinuousClock.now - overflowStarted < .seconds(2))
        await expectProcessExited(pidFile: overflowPIDFile)

        let descendantPIDFile = directory.appendingPathComponent("descendant.pid")
        let liveOutput = """
        Current session: 10% used · resets Sep 2 at 6:39pm (Asia/Shanghai)
        Current week (all models): 15% used · resets Sep 5 at 7:59pm (Asia/Shanghai)
        """
        let liveEnvelope = try? JSONSerialization.data(withJSONObject: [
            "is_error": false,
            "result": liveOutput,
        ])
        let inheritedWriterProvider = ClaudeCLIUsageProvider(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "(trap '' TERM; exec sleep 5) & echo $! > \"$1\"; exec /usr/bin/printf '%s' \"$2\"",
                "vibebuddy-test", descendantPIDFile.path,
                liveEnvelope.map { String(decoding: $0, as: UTF8.self) } ?? "",
            ],
            timeout: 1
        )
        let inheritedWriterStarted = ContinuousClock.now
        do {
            let snapshot = try await inheritedWriterProvider.fetch()
            #expect(snapshot.primary?.usedPercent == 10)
        } catch {
            Issue.record("Inherited writer should be cleaned up after valid output: \(error)")
        }
        #expect(ContinuousClock.now - inheritedWriterStarted < .seconds(1))
        await expectProcessExited(pidFile: descendantPIDFile)

        let detachedPIDFile = directory.appendingPathComponent("detached-descendant.pid")
        let detachedProvider = ClaudeCLIUsageProvider(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "(trap '' TERM; exec sleep 5 </dev/null >/dev/null 2>&1) & echo $! > \"$1\"; exec /usr/bin/printf '%s' \"$2\"",
                "vibebuddy-test", detachedPIDFile.path,
                liveEnvelope.map { String(decoding: $0, as: UTF8.self) } ?? "",
            ],
            timeout: 1
        )
        do {
            let snapshot = try await detachedProvider.fetch()
            #expect(snapshot.primary?.usedPercent == 10)
        } catch {
            Issue.record("Detached descendant should be cleaned up after valid output: \(error)")
        }
        await expectProcessExited(pidFile: detachedPIDFile)
    }

    @Test("a changed response shape is unavailable instead of becoming zero usage")
    func formatChange() {
        let malformed = Data(#"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300}}}}"#.utf8)
        let usage = Data(#"{"jsonrpc":"2.0","id":3,"result":{"summary":{}}}"#.utf8)

        #expect(throws: AccountUsageError.incompatibleFormat) {
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
        let collector = AccountUsageCollector(
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
        let collector = AccountUsageCollector(
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
        let collector = AccountUsageCollector(provider: provider, cache: cache, enabled: false)

        let bootstrapped = await collector.bootstrap(now: now)
        let refreshed = await collector.refresh(now: now)

        #expect(!bootstrapped.collectionEnabled)
        #expect(bootstrapped.snapshot == nil)
        #expect(refreshed.unavailableReason == .collectionDisabled)
        #expect(await provider.callCount() == 0)
        #expect(await cache.loadCount() == 0)
    }

    @Test("one provider can fail or be disabled without changing the other")
    func providerIsolation() async {
        let codexProvider = ScriptedUsageProvider([.success(sampleSnapshot(percent: 44))])
        let claudeProvider = ScriptedUsageProvider([.failure(.rateLimited)])
        let codex = AccountUsageCollector(
            provider: codexProvider,
            cache: MemoryUsageCache(),
            enabled: true
        )
        let claude = AccountUsageCollector(
            provider: claudeProvider,
            cache: MemoryUsageCache(sampleSnapshot(provider: .claude, percent: 12)),
            enabled: true
        )

        let codexState = await codex.refresh(now: now)
        let claudeState = await claude.refresh(now: now)
        _ = await claude.setEnabled(false, now: now)
        let disabledClaude = await claude.refresh(now: now)

        #expect(codexState.snapshot?.provider == .codex)
        #expect(codexState.snapshot?.primary?.usedPercent == 44)
        #expect(!codexState.isStale)
        #expect(claudeState.snapshot?.provider == .claude)
        #expect(claudeState.snapshot?.primary?.usedPercent == 12)
        #expect(claudeState.isStale)
        #expect(claudeState.unavailableReason == .rateLimited)
        #expect(!disabledClaude.collectionEnabled)
        #expect(await codexProvider.callCount() == 1)
        #expect(await claudeProvider.callCount() == 1)
    }

    @Test("a stale refresh cannot overwrite a rapid off-on cycle")
    func staleRefreshCannotOverwriteReenabledCollector() async {
        let provider = RacingUsageProvider(
            delayed: sampleSnapshot(percent: 99),
            immediate: sampleSnapshot(percent: 22)
        )
        let cache = MemoryUsageCache()
        let collector = AccountUsageCollector(
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
        #expect(await cache.saveCount() == 1)
    }

    @Test("a cache save already in flight cannot commit across disable and enable")
    func gatedCacheCommitAcrossRapidToggle() async {
        let staleSnapshot = sampleSnapshot(percent: 99)
        let cache = GatedUsageCache()
        let collector = AccountUsageCollector(
            provider: ScriptedUsageProvider([.success(staleSnapshot)]),
            cache: cache,
            enabled: true
        )

        let refresh = Task { await collector.refresh(now: now) }
        await cache.waitUntilSaveEntered()
        let disabled = await collector.setEnabled(false, now: now)
        let reenabled = await collector.setEnabled(true, now: now.addingTimeInterval(1))
        await cache.releaseSave()
        _ = await refresh.value

        #expect(!disabled.collectionEnabled)
        #expect(reenabled.collectionEnabled)
        #expect(reenabled.snapshot == nil)
        #expect(await cache.value() == nil)
        #expect(await cache.commitCount() == 0)
    }

    @Test("exponential backoff suppresses refresh work until the retry date")
    func backoff() async {
        let provider = ScriptedUsageProvider([
            .failure(.rateLimited),
            .failure(.rateLimited),
            .success(sampleSnapshot(percent: 33)),
        ])
        let collector = AccountUsageCollector(
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
        } catch let error as AccountUsageError {
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
        } catch let error as AccountUsageError {
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
        var monitor = AccountUsageAlertMonitor()
        let below = AccountUsageState.available(sampleSnapshot(percent: 89), nextRefreshAt: nil)
        let fresh = AccountUsageState.available(sampleSnapshot(percent: 90), nextRefreshAt: nil)
        let stale = AccountUsageState.stale(
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

        var restarted = AccountUsageAlertMonitor(alertedWindowKeys: monitor.alertedWindowKeys)
        #expect(restarted.newlyCrossed(in: fresh, thresholdPercent: 90).isEmpty)

        var resetSnapshot = sampleSnapshot(percent: 89)
        resetSnapshot.primary?.resetsAt = now.addingTimeInterval(7200)
        let reset = AccountUsageState.available(resetSnapshot, nextRefreshAt: nil)
        #expect(restarted.newlyCrossed(in: reset, thresholdPercent: 90).isEmpty)
        resetSnapshot.primary?.usedPercent = 91
        let crossedDuringQuiet = AccountUsageState.available(resetSnapshot, nextRefreshAt: nil)
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
        let cache = AccountUsageFileCache(fileURL: file)
        let collector = AccountUsageCollector(
            provider: ScriptedUsageProvider([.success(sampleSnapshot(percent: 40))]),
            cache: cache,
            enabled: true
        )

        _ = await collector.refresh(now: now)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
    }

    @Test("Grok is a first-class usage provider with its own cache and labels")
    func grokProviderRegistration() {
        #expect(AccountUsageProvider.allCases.contains(.grok))
        #expect(AccountUsageProvider.grok.displayName == "Grok")
        #expect(AccountUsageProvider.grok.rawValue == "grok")

        let home = URL(fileURLWithPath: "/Users/example")
        let cacheURL = AccountUsageFileCache.defaultFileURL(provider: .grok, home: home)
        #expect(cacheURL.lastPathComponent == "grok-usage.json")
        #expect(cacheURL != AccountUsageFileCache.defaultFileURL(provider: .codex, home: home))

        #expect(
            AccountUsageUnavailableReason.notLoggedIn.displayText(provider: .grok)
                == "Grok is not signed in"
        )
    }

    @Test("a Grok crossing alerts independently of the other providers")
    func grokAlertsAreIndependent() {
        var monitor = AccountUsageAlertMonitor()
        _ = monitor.newlyCrossed(
            in: .available(sampleSnapshot(provider: .grok, percent: 40), nextRefreshAt: nil),
            thresholdPercent: 90
        )
        _ = monitor.newlyCrossed(
            in: .available(sampleSnapshot(provider: .codex, percent: 95), nextRefreshAt: nil),
            thresholdPercent: 90
        )

        let alerts = monitor.newlyCrossed(
            in: .available(sampleSnapshot(provider: .grok, percent: 95), nextRefreshAt: nil),
            thresholdPercent: 90
        )
        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .primary)
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
        let collector = AccountUsageCollector(
            provider: ScriptedUsageProvider([.failure(.notLoggedIn)]),
            cache: MemoryUsageCache(),
            enabled: true
        )

        _ = await collector.refresh(now: now)

        #expect(reducer.sessions["working"] == before)
        #expect(reducer.sessions["working"]?.status == .working)
    }

    private func sampleSnapshot(
        provider: AccountUsageProvider = .codex,
        percent: Int
    ) -> AccountUsageSnapshot {
        AccountUsageSnapshot(
            provider: provider,
            planType: "pro",
            primary: AccountUsageWindow(
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

    private func claudeSleepingProvider(pidFile: URL, timeout: TimeInterval) -> ClaudeCLIUsageProvider {
        ClaudeCLIUsageProvider(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "echo $$ > \"$1\"; trap '' TERM; exec sleep 5",
                "vibebuddy-test", pidFile.path,
            ],
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

    /// A killed child (and any descendant that inherited the process group) dies
    /// asynchronously, so poll for its reaping rather than sampling once — under a
    /// loaded parallel test run the signal has often not landed yet.
    private func expectProcessExited(pidFile: URL) async {
        let pid = await waitForPID(in: pidFile)
        #expect(pid != nil)
        guard let pid else { return }
        for _ in 0..<500 {
            errno = 0
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("process \(pid) was never reaped")
    }
}

private actor ScriptedUsageProvider: AccountUsageProviding {
    private var results: [Result<AccountUsageSnapshot, AccountUsageError>]
    private var calls = 0

    init(_ results: [Result<AccountUsageSnapshot, AccountUsageError>]) {
        self.results = results
    }

    func fetch() async throws -> AccountUsageSnapshot {
        calls += 1
        guard !results.isEmpty else { throw AccountUsageError.unknown }
        return try results.removeFirst().get()
    }

    func callCount() -> Int { calls }
}

private actor RacingUsageProvider: AccountUsageProviding {
    private let delayed: AccountUsageSnapshot
    private let immediate: AccountUsageSnapshot
    private var calls = 0
    private var delayedContinuation: CheckedContinuation<AccountUsageSnapshot, Never>?

    init(delayed: AccountUsageSnapshot, immediate: AccountUsageSnapshot) {
        self.delayed = delayed
        self.immediate = immediate
    }

    func fetch() async throws -> AccountUsageSnapshot {
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

private actor MemoryUsageCache: AccountUsageCaching {
    private var snapshot: AccountUsageSnapshot?
    private var loads = 0
    private var saves = 0

    init(_ snapshot: AccountUsageSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() async -> AccountUsageSnapshot? {
        loads += 1
        return snapshot
    }

    func save(
        _ snapshot: AccountUsageSnapshot,
        permit: AccountUsageCacheCommitPermit
    ) async throws {
        permit.commit {
            saves += 1
            self.snapshot = snapshot
        }
    }

    func value() -> AccountUsageSnapshot? { snapshot }
    func loadCount() -> Int { loads }
    func saveCount() -> Int { saves }
}

private actor GatedUsageCache: AccountUsageCaching {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var committedSnapshot: AccountUsageSnapshot?
    private var commits = 0

    func load() async -> AccountUsageSnapshot? {
        committedSnapshot
    }

    func save(
        _ snapshot: AccountUsageSnapshot,
        permit: AccountUsageCacheCommitPermit
    ) async throws {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        permit.commit {
            committedSnapshot = snapshot
            commits += 1
        }
    }

    func waitUntilSaveEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func releaseSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func value() -> AccountUsageSnapshot? { committedSnapshot }
    func commitCount() -> Int { commits }
}
