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
/// `MenuBarExtra` label, so the head is rendered once into a **template**
/// `NSImage` from the same `BuddyCatFace` geometry as the pet (monochrome: one
/// colour, eyes punched to transparent); the system then tints it for
/// light/dark menu bars and selection — the same cat as the pet and the app
/// icon (ADR-0007, second amendment).
struct CatHeadIcon: View {
    var body: some View {
        Image(nsImage: MenuBarGlyph.cat)
            .resizable()
            .renderingMode(.template)
    }
}

enum MenuBarGlyph {
    @MainActor static let cat: NSImage = {
        let side: CGFloat = 18
        let renderer = ImageRenderer(content:
            BuddyCatFace(mood: .calm, showsBody: false, monochrome: true)
                .frame(width: side, height: BuddyCat.height(forWidth: side, showsBody: false))
                .frame(width: side, height: side))
        renderer.scale = 2
        let img = renderer.nsImage ?? NSImage(size: NSSize(width: side, height: side))
        img.size = NSSize(width: side, height: side)
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
    @Environment(\.openSettings) private var openSettings

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
            // the window to shoot without depending on a global hotkey or menu
            // click. A demo instance shares the installed app's bundle id, so
            // driving its menus over Accessibility is ambiguous — the env var is
            // the only reliable way to aim a screenshot at Settings.
            if ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" {
                AppActivationPolicy.enter()
                if ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO_PAGE"] == "settings" {
                    openSettings()
                } else {
                    openWindow(id: "dashboard")
                }
            }
        }
    }
}

private struct SessionListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MenuContent: View {
    @ObservedObject var model: MenuBarModel
    @State private var listContentHeight: CGFloat = 0
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
                sessionList
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

    /// Height cap for the session list — about eight compact rows. A short list
    /// takes its natural height; a long one scrolls inside the cap so the
    /// buttons above and the footer below never move off screen.
    private static let listMaxHeight: CGFloat = 320

    /// A ScrollView inside a MenuBarExtra window collapses to zero height
    /// unless it is given one explicitly, so the rows report their natural
    /// height and the scroller is sized to that, capped.
    private var sessionList: some View {
        ScrollView(.vertical) {
            sessionRows
                .background(GeometryReader { geo in
                    Color.clear.preference(key: SessionListHeightKey.self, value: geo.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(SessionListHeightKey.self) { listContentHeight = $0 }
        .frame(height: min(max(listContentHeight, 1), Self.listMaxHeight))
    }

    /// Three layers (see `MenuSessionList`): sessions that need the user stay
    /// pinned on top in the full two-line row; everything else is grouped by
    /// agent in compact one-line rows, and a folded group hides only its
    /// finished rows.
    private var sessionRows: some View {
        let list = model.menuSessionList
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(list.pinned) { row($0) }
            ForEach(list.groups) { group in
                if list.showsGroupHeaders { groupHeader(group) }
                ForEach(group.visibleSessions) { compactRow($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupHeader(_ group: MenuSessionList.Group) -> some View {
        Button {
            model.toggleMenuGroup(group.agent)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                    .frame(width: 10)
                Text(group.agent.displayName).font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                HStack(spacing: 7) {
                    ForEach([TaskPresentationState.thinking, .completeUnread, .idle], id: \.self) { state in
                        let count = group.summary.count(for: state)
                        if count > 0 {
                            HStack(spacing: 3) {
                                TaskStatusIndicator(state, size: 7)
                                Text("\(count)").monospacedDigit()
                            }
                            .accessibilityLabel("\(count) \(state.label)")
                        }
                    }
                }
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group.isCollapsed ? "Show finished sessions" : "Hide finished sessions")
        .accessibilityLabel("\(group.agent.displayName), \(group.sessions.count) sessions")
        .accessibilityValue(group.isCollapsed ? "collapsed" : "expanded")
    }

    /// One-line row for sessions that don't need the user: the dot carries the
    /// state, the trailing text says what the agent is doing and since when.
    private func compactRow(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            TaskStatusIndicator(session.presentationState, size: 8)
            Text(session.project)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Text(ToolActivity.label(for: session))
                Text("·").foregroundStyle(.tertiary)
                Text(session.updatedAt, style: .relative).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
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
