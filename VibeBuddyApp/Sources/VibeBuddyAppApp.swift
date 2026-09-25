import SwiftUI
import VibeBuddyKit

@main
struct VibeBuddyAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connection = ConnectionStore()
    @StateObject private var connectionSync = RemoteConnectionSyncController()
    @StateObject private var dashboard: DashboardStore
    @StateObject private var voice: VoiceChat

    init() {
        // Gemini was removed; its settings fall back before any view reads them.
        // Read-aloud that followed a Gemini conversation reads with system
        // speech rather than being moved to Qwen once the provider key goes.
        let defaults = UserDefaults.standard
        if defaults.string(forKey: VoiceSettings.providerKey) == "gemini",
           defaults.object(forKey: PhoneReadAloudSelection.defaultsKey) == nil {
            defaults.set(PhoneReadAloudSelection.system.rawValue, forKey: PhoneReadAloudSelection.defaultsKey)
        }
        VoiceSettings.removeRetiredGeminiSettings()
        let dash = DashboardStore()
        _dashboard = StateObject(wrappedValue: dash)
        _voice = StateObject(wrappedValue: VoiceChat(
            contextProvider: { [weak dash] in dash?.buddyContext ?? [] },
            actionHandler: { [weak dash] action in await dash?.performVoiceAction(action) ?? "" }))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(connection)
                .environmentObject(connectionSync)
                .environmentObject(dashboard)
                .environmentObject(voice)
                .onOpenURL { dashboard.open($0) }
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var connectionSync: RemoteConnectionSyncController

    private struct SyncActivity: Equatable {
        let pairing: PairingPayload?
        let active: Bool
        let demo: Bool
    }

    var body: some View {
        NavigationStack {
            if connection.pairing != nil || connection.demo {
                DashboardView()
            } else {
                ConnectView()
            }
        }
        .onDisappear { dashboard.stop() }
        .task {
            if !Self.skipNotifications {
                PushRegistration.shared.registerForRemoteNotifications()
                PushRegistration.shared.update(pairing: connection.pairing)
            }
        }
        .task(id: SyncActivity(pairing: connection.pairing, active: scenePhase == .active, demo: connection.demo)) {
            await connectionSync.run(connection: connection, enabled: scenePhase == .active && !connection.demo) {
                guard let pairing = connection.pairing else { return nil }
                return dashboard.connectionSourceID(for: pairing)
            }
        }
        .onChange(of: connectionSync.state) { oldValue, newValue in
            if case .connected = oldValue { return }
            if case .connected = newValue, dashboard.state != .connected,
               let pairing = connection.pairing {
                dashboard.start(pairing)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // A launch into the background can read the defaults before the
            // device has been unlocked since it booted and find nothing; the
            // store keeps that answer for the life of the process. Read again
            // whenever the app comes forward, when the defaults are readable,
            // so a saved Mac cannot be lost to a background launch.
            if phase == .active { connection.reloadSavedPairing() }
        }
        .onChange(of: connection.pairing) { _, newValue in
            if newValue == nil { dashboard.stop() }
            if !Self.skipNotifications {
                PushRegistration.shared.update(pairing: newValue)
            }
        }
    }

    private static var skipNotifications: Bool {
        ProcessInfo.processInfo.environment["VIBEBUDDY_SKIP_NOTIFICATIONS"] == "1"
    }
}
