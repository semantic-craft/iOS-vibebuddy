import Foundation
import VibeBuddyKit
import VibeBuddyMacCore

/// Owns provider account-usage collection: the per-provider collectors, their
/// independent refresh loops, the quota alert monitor and its persistence, and
/// publishing the normalized allowance into the session store.
///
/// This is intentionally separate from `MenuBarModel`'s session pipeline:
/// refresh errors never enter SessionStore or the progress notification path,
/// and the loops here have their own cadence rather than the 2-second poll.
@MainActor
final class AccountUsageCoordinator: ObservableObject {
    @Published private(set) var states: [AccountUsageProvider: AccountUsageState] = [:] {
        didSet { publishProviderQuota() }
    }
    @Published private(set) var collectionEnabled: [AccountUsageProvider: Bool] = [:]

    private let store: SessionStore
    private let notifier: UserNotificationsNotifier
    /// Set after `MenuBarModel` has its delivery recorder. Local post, push and
    /// the delivery log all go through this so quota honours the category switch.
    var onUsageAlert: ((AccountUsageProvider, AccountUsageWindow, Int) -> Void)?
    private let liveFeed: AccountUsageLiveFeed?
    private var liveTask: Task<Void, Never>?
    /// How long a live sample keeps the spawning collector idle. Claude's
    /// status line reports on every event, so 15 minutes of silence means no
    /// session is running; the Codex monitor re-reads every 10 minutes while
    /// connected, so 20 minutes of silence means it disconnected.
    static func liveHold(for provider: AccountUsageProvider) -> TimeInterval {
        switch provider {
        case .claude: 15 * 60
        case .codex: 20 * 60
        case .grok: 15 * 60
        case .cursor: 15 * 60
        }
    }
    private let collectors: [AccountUsageProvider: AccountUsageCollector]
    private var alertMonitor: AccountUsageAlertMonitor
    private var tasks: [AccountUsageProvider: Task<Void, Never>] = [:]
    private var generations: [AccountUsageProvider: UInt64] = [:]
    private static let alertedWindowsKey = "accountUsageAlertedWindows"

    init(store: SessionStore, notifier: UserNotificationsNotifier, liveFeed: AccountUsageLiveFeed? = nil) {
        self.store = store
        self.notifier = notifier
        self.liveFeed = liveFeed
        let codexEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey(for: .codex), default: true)
        let claudeEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey(for: .claude), default: true)
        let grokEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey(for: .grok), default: true)
        let cursorEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey(for: .cursor), default: true)
        collectionEnabled = [
            .codex: codexEnabled,
            .claude: claudeEnabled,
            .grok: grokEnabled,
            .cursor: cursorEnabled,
        ]
        states = [
            .codex: codexEnabled
                ? .unavailable(.notYetLoaded, lastAttemptAt: nil, nextRefreshAt: nil)
                : .disabled,
            .claude: claudeEnabled
                ? .unavailable(.notYetLoaded, lastAttemptAt: nil, nextRefreshAt: nil)
                : .disabled,
            .grok: grokEnabled
                ? .unavailable(.notYetLoaded, lastAttemptAt: nil, nextRefreshAt: nil)
                : .disabled,
            .cursor: cursorEnabled
                ? .unavailable(.notYetLoaded, lastAttemptAt: nil, nextRefreshAt: nil)
                : .disabled,
        ]
        collectors = [
            .codex: AccountUsageCollector(
                provider: CodexAppServerUsageProvider(),
                cache: AccountUsageFileCache(provider: .codex),
                enabled: codexEnabled
            ),
            .claude: AccountUsageCollector(
                provider: ClaudeCLIUsageProvider(),
                cache: AccountUsageFileCache(provider: .claude),
                enabled: claudeEnabled
            ),
            .grok: AccountUsageCollector(
                provider: GrokUsageProvider(),
                cache: AccountUsageFileCache(provider: .grok),
                enabled: grokEnabled
            ),
            .cursor: AccountUsageCollector(
                provider: CursorUsageProvider(),
                cache: AccountUsageFileCache(provider: .cursor),
                enabled: cursorEnabled
            ),
        ]
        alertMonitor = AccountUsageAlertMonitor(
            alertedWindowKeys: Self.loadAlertedWindows()
        )
        // `didSet` does not fire for the assignment inside `init`, and a provider
        // that is switched off never changes state again. Publish once here so
        // every provider reaches the snapshot from launch, saying "waiting" or
        // "turned off" rather than being absent.
        publishProviderQuota()
    }

    /// Begin the refresh loops for every provider the user left switched on.
    /// Not called by the demo instance, which never touches real accounts.
    func start() {
        for provider in AccountUsageProvider.allCases where isCollectionEnabled(provider) {
            startCollection(provider)
        }
        guard let liveFeed, liveTask == nil else { return }
        // Live samples take the same path a fetch does — state, cache, alert,
        // quota publish — and push the provider's next fetch out by the hold.
        liveTask = Task { [weak self] in
            let subscription = await liveFeed.subscribe()
            defer { Task { await liveFeed.unsubscribe(subscription.id) } }
            for await snapshot in subscription.stream {
                guard !Task.isCancelled, let self else { return }
                let provider = snapshot.provider
                guard self.isCollectionEnabled(provider), let collector = self.collectors[provider] else { continue }
                let state = await collector.acceptLive(snapshot, holdFor: Self.liveHold(for: provider))
                guard !Task.isCancelled, self.isCollectionEnabled(provider) else { continue }
                self.states[provider] = state
                self.checkAlert(state)
            }
        }
    }

    func isCollectionEnabled(_ provider: AccountUsageProvider) -> Bool {
        collectionEnabled[provider] == true
    }

    func state(for provider: AccountUsageProvider) -> AccountUsageState {
        states[provider] ?? .disabled
    }

    func setCollectionEnabled(_ enabled: Bool, provider: AccountUsageProvider) {
        guard enabled != isCollectionEnabled(provider) else { return }
        collectionEnabled[provider] = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey(for: provider))
        if enabled {
            startCollection(provider)
        } else {
            let generation = (generations[provider] ?? 0) &+ 1
            generations[provider] = generation
            let previousTask = tasks[provider]
            previousTask?.cancel()
            states[provider] = .disabled
            guard let collector = collectors[provider] else { return }
            tasks[provider] = Task { [weak self] in
                let disabled = await collector.setEnabled(false)
                await previousTask?.value
                guard !Task.isCancelled,
                      let self,
                      self.generations[provider] == generation,
                      !self.isCollectionEnabled(provider) else { return }
                self.states[provider] = disabled
            }
        }
    }

    /// Start the independent account-usage loop. It has its own cadence,
    /// timeout/cache/backoff policy and never participates in the session
    /// snapshot poll that drives the menu bar.
    private func startCollection(_ provider: AccountUsageProvider) {
        let generation = (generations[provider] ?? 0) &+ 1
        generations[provider] = generation
        let previousTask = tasks[provider]
        previousTask?.cancel()
        guard let collector = collectors[provider] else { return }
        tasks[provider] = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled,
                  let self,
                  self.generations[provider] == generation,
                  self.isCollectionEnabled(provider) else { return }
            let initial = await collector.setEnabled(true)
            guard !Task.isCancelled,
                  self.generations[provider] == generation,
                  self.isCollectionEnabled(provider) else { return }
            self.states[provider] = initial

            while !Task.isCancelled,
                  self.generations[provider] == generation,
                  self.isCollectionEnabled(provider) {
                let state = await collector.refresh()
                guard !Task.isCancelled,
                      self.generations[provider] == generation,
                      self.isCollectionEnabled(provider) else { return }
                self.states[provider] = state
                self.checkAlert(state)

                let delay = max(1, state.nextRefreshAt?.timeIntervalSinceNow ?? 60)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    /// Hand the runtime snapshot owner the normalized allowance, so the phone
    /// and the Watch read the same numbers the menu bar shows. Turning a
    /// provider off is state too: it publishes an explicit unavailable rather
    /// than leaving the last value to age quietly on someone's wrist.
    private func publishProviderQuota() {
        let quota = ProviderQuota.all(from: states)
        Task { [store] in await store.setProviderQuota(quota) }
    }

    private func checkAlert(_ state: AccountUsageState) {
        let defaults = UserDefaults.standard
        let threshold = defaults.object(forKey: "accountUsageAlertThreshold") == nil
            ? 90
            : defaults.integer(forKey: "accountUsageAlertThreshold")
        let windows = alertMonitor.newlyCrossed(
            in: state,
            thresholdPercent: threshold,
            notificationsSuppressed: false // Quota uses its category switch, independently of Quiet.
        )
        Self.saveAlertedWindows(alertMonitor.alertedWindowKeys)
        guard let provider = state.snapshot?.provider else { return }
        for window in windows {
            if let onUsageAlert {
                onUsageAlert(provider, window, threshold)
            } else {
                Task { await notifier.notifyUsage(provider: provider, window: window, threshold: threshold) }
            }
        }
    }

    private static func loadAlertedWindows() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: alertedWindowsKey),
              let keys = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return keys
    }

    private static func saveAlertedWindows(_ keys: Set<String>) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        UserDefaults.standard.set(data, forKey: alertedWindowsKey)
    }

    private static func enabledKey(for provider: AccountUsageProvider) -> String {
        "\(provider.rawValue)UsageCollectionEnabled"
    }

    deinit {
        for task in tasks.values { task.cancel() }
        liveTask?.cancel()
    }
}
