import SwiftUI
import AppKit
import os
import VibeBuddyKit
import VibeBuddyMacCore

@main
struct VibeBuddyMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: MenuBarModel
    private let role: AppRuntime.Role
    // Settings → General → "Show icon in menu bar". `isInserted` keeps the
    // MenuBarExtra scene in the graph (so its label still bridges the global
    // hotkey to openWindow) while removing the icon from the menu bar.
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    init() {
        let role = AppRuntime.role
        self.role = role
        _model = StateObject(wrappedValue: MenuBarModel(runtimeEnabled: role == .primary))
    }

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { role == .primary && showMenuBarIcon },
            set: { showMenuBarIcon = $0 })) {
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

private enum AppRuntime {
    enum Role { case primary, secondary }

    private static let log = Logger(subsystem: "com.vibebuddy.app", category: "single-instance")
    private static let openDashboardNotification = Notification.Name("com.vibebuddy.mac.openDashboard")
    nonisolated(unsafe) private static var lock: SingleInstanceLock?

    static let role: Role = {
        if ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" { return .primary }
        do {
            if let acquired = try SingleInstanceLock.acquire(lockFileURL: try SingleInstanceLock.defaultLockFileURL()) {
                lock = acquired
                return .primary
            }
            return .secondary
        } catch {
            log.error("single-instance lock failed; continuing as primary: \(String(describing: error), privacy: .public)")
            return .primary
        }
    }()

    static func requestPrimaryDashboard() {
        DistributedNotificationCenter.default().postNotificationName(
            openDashboardNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
    }

    static func observeOpenRequests() -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: openDashboardNotification,
            object: nil,
            queue: .main) { _ in
                NotificationCenter.default.post(name: .openDashboard, object: nil)
            }
    }
}

/// Hide the Dock icon — menu-bar-only app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.vibebuddy.app", category: "lifecycle")
    private var openRequestObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppRuntime.role == .primary else {
            AppRuntime.requestPrimaryDashboard()
            Self.log.notice("secondary instance requested primary dashboard and will terminate")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        // Keep the background daemon alive. macOS cleanly auto-terminates idle
        // accessory apps to reclaim resources (no crash report — exactly the
        // observed ~4-min clean exits). Opt out, since we run an HTTP/WS server.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination(
            "vibebuddy runs a background daemon (HTTP/WebSocket server + hooks) that must stay alive")
        openRequestObserver = AppRuntime.observeOpenRequests()
        GlobalHotkey.install()
        Self.log.notice("didFinishLaunching")
    }

    /// A menu-bar app must NOT quit when the dashboard/settings window closes.
    /// (Likely cause of the observed clean exits: a window opens via
    /// AppActivationPolicy.enter() → .regular, then closing the last window
    /// terminates the app.) Returning false keeps the daemon alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Self.log.notice("shouldTerminateAfterLastWindowClosed -> false")
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.log.notice("applicationShouldTerminate (someone asked us to quit)")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.log.notice("applicationWillTerminate")
    }
}

/// The cat-head menu-bar mark. A SwiftUI `Canvas` doesn't render reliably in a
/// `MenuBarExtra` label, so the head is drawn once into a **template** `NSImage`
/// (eyes punched out with `destinationOut`); the system then tints it for
/// light/dark menu bars and selection — the same cat identity as the pet and the
/// app icon (ADR-0007, amended: cat on both platforms).
struct CatHeadIcon: View {
    var body: some View {
        Image(nsImage: MenuBarGlyph.cat)
            .resizable()
            .renderingMode(.template)
    }
}

enum MenuBarGlyph {
    static let cat: NSImage = {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s), flipped: true) { rect in
            let w = rect.width, h = rect.height
            // y grows downward (flipped): ears on top, rounded head below.
            let solid = NSBezierPath()
            // Triangular ears.
            let leftEar = NSBezierPath()
            leftEar.move(to: NSPoint(x: 0.22 * w, y: 0.40 * h))
            leftEar.line(to: NSPoint(x: 0.30 * w, y: 0.04 * h))
            leftEar.line(to: NSPoint(x: 0.50 * w, y: 0.36 * h))
            leftEar.close()
            let rightEar = NSBezierPath()
            rightEar.move(to: NSPoint(x: 0.78 * w, y: 0.40 * h))
            rightEar.line(to: NSPoint(x: 0.70 * w, y: 0.04 * h))
            rightEar.line(to: NSPoint(x: 0.50 * w, y: 0.36 * h))
            rightEar.close()
            solid.append(leftEar)
            solid.append(rightEar)
            // Rounded head.
            solid.append(NSBezierPath(roundedRect: NSRect(x: 0.17 * w, y: 0.32 * h, width: 0.66 * w, height: 0.62 * h),
                                      xRadius: 0.22 * w, yRadius: 0.22 * w))
            NSColor.black.setFill()
            solid.fill()
            // Punch out the two eyes so the system tint shows through cleanly.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let eyes = NSBezierPath()
            let r: CGFloat = 0.085 * w
            for ex in [0.38, 0.62] as [CGFloat] {
                eyes.appendOval(in: NSRect(x: ex * w - r, y: 0.62 * h - r, width: r * 2, height: r * 2))
            }
            eyes.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        img.isTemplate = true
        return img
    }()
}

/// The MenuBarExtra label. Always instantiated while the app runs, so its
/// `.onReceive` is a reliable bridge from the global Carbon hotkey
/// (`.openDashboard` notification) to SwiftUI's `openWindow`, which is only
/// available from a View's environment.
struct MenuBarLabel: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = model.presentationSummary.primaryState
        let count = model.presentationSummary.count(for: state)
        HStack(spacing: 3) {
            // A stable cat-head mark (matches the pet + app icon), monochrome so
            // the system tints it for light/dark. State shows as a badge + count,
            // not a shape change, so the silhouette stays recognizable.
            CatHeadIcon()
                .frame(width: 17, height: 17)
                .overlay(alignment: .topTrailing) {
                    if state != .unassigned {
                        TaskStatusIndicator(state, size: 6)
                            .offset(x: 1.5, y: -0.5)
                    }
                }
            if state == .error || state == .requiresInput {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .accessibilityLabel("\(count) \(state.label)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDashboard)) { _ in
            AppActivationPolicy.enter()
            openWindow(id: "dashboard")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleGlance)) { _ in
            model.setShowGlance(!model.showGlance)
        }
        .task {
            // Screenshot/exploration mode is intentionally self-contained: open
            // the dashboard without depending on a global hotkey or menu click.
            if ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" {
                AppActivationPolicy.enter()
                openWindow(id: "dashboard")
            }
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

            Button {
                model.setShowGlance(!model.showGlance)
            } label: {
                HStack(spacing: 8) {
                    Label(model.showGlance ? "Hide Glance" as LocalizedStringKey : "Show Glance",
                          systemImage: model.showGlance ? "eye.slash.fill" : "eye.fill")
                        .fontWeight(.medium)
                    Spacer()
                    Text(model.toggleGlanceHotkey.displayString)
                        .font(.callout.weight(.medium).monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(model.showGlance ? .secondary : .blue)

            HStack {
                Text("vibebuddy").font(.headline)
                Spacer()
                Text(model.pairingAddress)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.pairedPhone != nil ? "iphone.gen3" : "iphone.slash")
                    .foregroundStyle(model.pairedPhone != nil ? .green : .secondary)
                    .frame(width: 18)
                if let phone = model.pairedPhone {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paired: \(phone.name)")
                            .foregroundStyle(.primary)
                        if !phone.subtitle.isEmpty {
                            Text(phone.subtitle)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Text("Last seen \(phone.lastSeen.formatted(date: .omitted, time: .shortened))")
                            Text(phone.pushRegistered ? "Push ready" as LocalizedStringKey : "Push pending")
                        }
                        .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("No phone paired")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption)

            HStack(spacing: 12) {
                ForEach([TaskPresentationState.error, .requiresInput, .thinking, .completeUnread, .idle], id: \.self) { state in
                    counter(model.presentationSummary.count(for: state), state)
                }
            }

            Divider()

            if model.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No sessions reporting").font(.caption.weight(.medium))
                    Text("Start a turn or repair hooks in Settings.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
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
                Button {
                    AppActivationPolicy.enter()
                    Updater.shared.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.down.circle")
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

    private func counter(_ value: Int, _ state: TaskPresentationState) -> some View {
        HStack(spacing: 5) {
            TaskStatusIndicator(state, size: 8)
            Image(systemName: state.symbolName)
            Text("\(value)").monospacedDigit()
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(value > 0
                         ? AnyShapeStyle(Color(taskStatus: state.colorToken))
                         : AnyShapeStyle(.secondary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(state.label)")
    }

    private func row(_ session: AgentSession) -> some View {
        HStack(alignment: .top, spacing: 9) {
            TaskStatusIndicator(session.presentationState, size: 9)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.project).font(.callout.weight(.semibold))
                    AgentSourceBadge(agent: session.agent)
                    if let branch = session.branch {
                        Text(branch).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Text(ToolActivity.label(for: session)).fontWeight(.medium)
                    Text("·").foregroundStyle(.tertiary)
                    Text(session.updatedAt, style: .relative).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

}
