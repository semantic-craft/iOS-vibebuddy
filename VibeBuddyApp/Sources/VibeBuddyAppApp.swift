import SwiftUI
import VibeBuddyKit

@main
struct VibeBuddyAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connection = ConnectionStore()
    @StateObject private var dashboard = DashboardStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(connection)
                .environmentObject(dashboard)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var connection: ConnectionStore

    var body: some View {
        NavigationStack {
            if connection.pairing != nil || connection.demo {
                DashboardView()
            } else {
                ConnectView()
            }
        }
        .task {
            PushRegistration.shared.registerForRemoteNotifications()
            PushRegistration.shared.update(pairing: connection.pairing)
        }
        .onChange(of: connection.pairing) { _, newValue in
            PushRegistration.shared.update(pairing: newValue)
        }
    }
}
