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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("vibebuddy").font(.headline)
            if let pairing = model.pairing {
                Text("\(pairing.host):\(pairing.port)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                counter("\(model.needsResponse)", "exclamationmark.circle.fill", .orange)
                counter("\(model.working)", "hourglass", .blue)
                counter("\(model.done)", "checkmark.circle.fill", .green)
            }

            Divider()
            if model.sessions.isEmpty {
                Text("No active sessions").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.sessions) { session in
                    row(session)
                }
            }

            Divider()
            DisclosureGroup("Pair a phone") {
                if let qr = model.qrImage {
                    Image(nsImage: qr).interpolation(.none)
                        .frame(width: 200, height: 200)
                    Text("Scan in the vibebuddy app")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider()
            Button("Quit vibebuddy") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 290)
    }

    private func counter(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(color)
    }

    private func row(_ session: AgentSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color(for: session.status)).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.project).font(.caption).bold()
                    if let branch = session.branch {
                        Text(branch).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let summary = session.summary {
                    Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private func color(for status: SessionStatus) -> Color {
        switch status {
        case .needsResponse: .orange
        case .working: .blue
        case .done: .green
        }
    }
}
