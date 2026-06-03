import SwiftUI
import VibeBuddyKit

@main
struct VibeBuddyAppApp: App {
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
            if connection.pairing != nil {
                DashboardView()
            } else {
                ConnectView()
            }
        }
    }
}
