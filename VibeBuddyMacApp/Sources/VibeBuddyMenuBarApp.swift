import SwiftUI
import AppKit
import VibeBuddyKit

@main
struct VibeBuddyMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = MenuBarModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.needsResponse > 0
                  ? "bell.badge.fill" : "dot.radiowaves.left.and.right")
            if model.needsResponse > 0 { Text("\(model.needsResponse)") }
        }
        .menuBarExtraStyle(.window)

        Window("vibebuddy", id: "dashboard") {
            DashboardView(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Hide the Dock icon — menu-bar-only app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuContent: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("打开 Dashboard") {
                NSApp.setActivationPolicy(.regular)   // show in Dock/⌘-tab while the window is open
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)

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
                Text("没有进行中的会话")
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
                    Text("在 vibebuddy iOS app 里扫这个码")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            Divider()

            Toggle("开机自启", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .font(.callout)

            Button("退出 vibebuddy") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
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
