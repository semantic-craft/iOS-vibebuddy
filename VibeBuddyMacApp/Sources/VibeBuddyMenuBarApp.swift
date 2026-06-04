import SwiftUI
import AppKit
import VibeBuddyKit

@main
struct VibeBuddyMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = MenuBarModel()
    // Settings → General → "Show icon in menu bar". `isInserted` keeps the
    // MenuBarExtra scene in the graph (so its label still bridges the global
    // hotkey to openWindow) while removing the icon from the menu bar.
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("vibebuddy", id: "dashboard") {
            DashboardView(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Hide the Dock icon — menu-bar-only app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        GlobalHotkey.install()
    }
}

/// The MenuBarExtra label. Always instantiated while the app runs, so its
/// `.onReceive` is a reliable bridge from the global Carbon hotkey
/// (`.openDashboard` notification) to SwiftUI's `openWindow`, which is only
/// available from a View's environment.
struct MenuBarLabel: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Image(systemName: model.needsResponse > 0
                  ? "bell.badge.fill" : "dot.radiowaves.left.and.right")
            if model.needsResponse > 0 { Text("\(model.needsResponse)") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDashboard)) { _ in
            AppActivationPolicy.enter()
            openWindow(id: "dashboard")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                AppActivationPolicy.enter()
                openWindow(id: "dashboard")
            } label: {
                HStack(spacing: 8) {
                    Label("Open Dashboard", systemImage: "macwindow")
                    Spacer()
                    Text(model.openDashboardHotkey.displayString)
                        .font(.callout.weight(.medium).monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            HStack {
                Text("vibebuddy").font(.headline)
                Spacer()
                if let pairing = model.pairing {
                    Text("\(pairing.host):\(pairing.port)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                counter(model.needsResponse, "exclamationmark.circle.fill", .orange)
                counter(model.working, "hourglass", .blue)
                counter(model.done, "checkmark.circle.fill", .green)
            }

            Divider()

            if model.sessions.isEmpty {
                Text("No active sessions")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 9) {
                    ForEach(model.sessions) { row($0) }
                }
            }

            Divider()

            DisclosureGroup("Pair a phone") {
                if let qr = model.qrImage {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: 176, height: 176)
                        .padding(12)
                        .background(.white)
                        .clipShape(.rect(cornerRadius: 8))
                    Text("Scan this in the vibebuddy iOS app")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            Divider()

            HStack {
                Button {
                    AppActivationPolicy.enter()
                    openSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Quit vibebuddy") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func counter(_ value: Int, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text("\(value)").monospacedDigit()
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(value > 0 ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
    }

    private func row(_ session: AgentSession) -> some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: session.status))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.project).font(.callout.weight(.semibold))
                    if let branch = session.branch {
                        Text(branch).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if let summary = session.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func color(for status: SessionStatus) -> Color {
        switch status {
        case .needsResponse: .orange
        case .working: .blue
        case .done: .green
        }
    }
}
