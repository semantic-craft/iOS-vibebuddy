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
    // Visibility affects only the icon; app-level commands stay available.
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    init() {
        let role = AppRuntime.role
        self.role = role
        let model = MenuBarModel(runtimeEnabled: role == .primary)
        _model = StateObject(wrappedValue: model)
        delegate.model = model
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

        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openAppSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Open Dashboard") {
                    NotificationCenter.default.post(name: .openDashboard, object: nil)
                }
            }
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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.vibebuddy.app", category: "lifecycle")
    private var openRequestObserver: NSObjectProtocol?
    var model: MenuBarModel!
    private var windows: AppWindows?

    @objc private func openDashboard() {
        windows?.showDashboard()
    }

    @objc private func openSettings() {
        windows?.showSettings()
    }

    @objc private func toggleGlance() {
        model.setShowGlance(!model.showGlance)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A visible Glance or Settings window does not satisfy a Dashboard request.
        openDashboard()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppRuntime.role == .primary else {
            AppRuntime.requestPrimaryDashboard()
            Self.log.notice("secondary instance requested primary dashboard and will terminate")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        windows = AppWindows(
            dashboard: AnyView(DashboardView(model: model)),
            settings: AnyView(SettingsView(model: model)))
        NotificationCenter.default.addObserver(self, selector: #selector(openDashboard), name: .openDashboard, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings), name: .openAppSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toggleGlance), name: .toggleGlance, object: nil)
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
        // Explicit launches show a usable window even when the menu icon is hidden.
        // Login-item launches remain quiet.
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !loginLaunch {
            if ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO_PAGE"] == "settings" {
                openSettings()
            } else {
                openDashboard()
            }
        }
    }

    /// Closing ordinary windows must leave the daemon and Glance running.
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

/// Presentation only; hiding the label cannot disconnect app commands.
struct MenuBarLabel: View {
    @ObservedObject var model: MenuBarModel

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

    }
}

private struct SessionListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The menu-bar dropdown, Companion style: the cat says how things are, the two
/// big actions, pairing, then the sessions in the same three state groups as
/// the dashboard (docs/design/mac-companion-redesign.md).
struct MenuContent: View {
    @ObservedObject var model: MenuBarModel
    @State private var listContentHeight: CGFloat = 0
    @State private var greet = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryHead

            Button {
                NotificationCenter.default.post(name: .openDashboard, object: nil)
            } label: {
                HStack(spacing: 8) {
                    Label("Open Dashboard", systemImage: "macwindow")
                    Spacer()
                    Text(model.openDashboardHotkey.displayString)
                        .font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent)))

            Button {
                model.setShowGlance(!model.showGlance)
            } label: {
                HStack(spacing: 8) {
                    Label(model.showGlance ? "Hide Glance" as LocalizedStringKey : "Show Glance",
                          systemImage: model.showGlance ? "eye.slash.fill" : "eye.fill")
                    Spacer()
                    Text(model.toggleGlanceHotkey.displayString)
                        .font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PillButtonStyle(kind: .soft))

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.pairedPhone != nil ? "iphone.gen3" : "iphone.slash")
                    .foregroundStyle(model.pairedPhone != nil ? MacTheme.accent : MacTheme.ink3)
                    .frame(width: 18)
                if let phone = model.pairedPhone {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paired: \(phone.name)").foregroundStyle(MacTheme.ink)
                        if !phone.subtitle.isEmpty {
                            Text(phone.subtitle).foregroundStyle(MacTheme.ink2)
                        }
                        HStack(spacing: 6) {
                            Text("Last seen \(phone.lastSeen.formatted(date: .omitted, time: .shortened))")
                            Text(phone.pushRegistered ? "Push ready" as LocalizedStringKey : "Push pending")
                        }
                        .foregroundStyle(MacTheme.ink3)
                    }
                } else {
                    Text("No phone paired").foregroundStyle(MacTheme.ink2)
                }
                Spacer()
                Text(model.pairingAddress).font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
            }
            .font(MacTheme.font(11, .semibold))

            Divider().overlay(MacTheme.line)

            if model.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No sessions reporting").font(MacTheme.font(12, .heavy)).foregroundStyle(MacTheme.ink)
                    Text("Start a turn or repair hooks in Settings.")
                        .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
            } else {
                sessionList
            }

            Divider().overlay(MacTheme.line)

            DisclosureGroup("Pair a phone") {
                if let qr = model.qrImage {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: 176, height: 176)
                        .padding(12)
                        .background(.white)
                        .clipShape(.rect(cornerRadius: 8))
                    Text("Scan this in the vibebuddy iOS app")
                        .font(MacTheme.font(10, .semibold)).foregroundStyle(MacTheme.ink2)
                }
            }
            .font(MacTheme.font(12, .heavy))
            .foregroundStyle(MacTheme.ink)

            Divider().overlay(MacTheme.line)

            HStack {
                Button {
                    NotificationCenter.default.post(name: .openAppSettings, object: nil)
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    Updater.shared.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Quit vibebuddy") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(MacTheme.font(12, .heavy))
            .foregroundStyle(MacTheme.ink2)
        }
        .padding(16)
        .frame(width: 310)
        .background(MacTheme.bg)
    }

    /// Round 5: the cat says one line, the second line carries the rest.
    private var summaryHead: some View {
        let summary = model.presentationSummary
        return HStack(spacing: 10) {
            PetFace(state: model.buddyState, voice: .init(model.voiceChat.phase), greet: greet, bare: true, scale: 0.7)
                .onTapGesture { greet += 1; model.voiceChat.toggle() }
            VStack(alignment: .leading, spacing: 2) {
                Text(MacSummaryCopy.moodLine(summary)).font(MacTheme.font(15, .black)).foregroundStyle(MacTheme.ink)
                let rest = MacSummaryCopy.restLine(summary)
                if !rest.isEmpty {
                    Text(rest).font(MacTheme.font(11, .bold)).foregroundStyle(MacTheme.ink2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Height cap for the session list — about eight compact rows. A short list
    /// takes its natural height; a long one scrolls inside the cap so the
    /// buttons above and the footer below never move off screen.
    private static let listMaxHeight: CGFloat = 340

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

    /// The same three buckets as the dashboard. Needs-you rows keep the full
    /// summary-first row; the other groups use the compact one-liner.
    private var sessionRows: some View {
        let groups = StateGroups(model.sessions)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(groups.buckets) { group in
                HStack(spacing: 6) {
                    Text(group.title).font(MacTheme.font(11, .black)).foregroundStyle(MacTheme.ink)
                    Text("\(group.sessions.count)").font(MacTheme.font(11, .heavy)).foregroundStyle(MacTheme.ink2)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(MacTheme.bg2, in: Capsule())
                ForEach(group.sessions) { s in
                    if group.warm { fullRow(s) } else { compactRow(s) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fullRow(_ session: AgentSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StateGlyph(state: session.presentationState, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.project).font(MacTheme.font(11, .bold)).foregroundStyle(MacTheme.ink2)
                    AgentBadge(agent: session.agent)
                    Spacer(minLength: 4)
                    Text(session.updatedAt, style: .relative).font(MacTheme.font(10, .semibold))
                        .foregroundStyle(MacTheme.ink3).monospacedDigit()
                }
                Text(session.summary ?? ToolActivity.label(for: session))
                    .font(MacTheme.font(13, .heavy)).foregroundStyle(MacTheme.ink).lineLimit(1)
                Text(ToolActivity.label(for: session))
                    .font(MacTheme.font(9, .heavy)).textCase(.uppercase).kerning(0.5)
                    .foregroundStyle(MacTheme.status(session.presentationState))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard(radius: 10)
    }

    /// One-line row for sessions that don't need the user: the glyph carries the
    /// state, the trailing text says what the agent is doing and since when.
    private func compactRow(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            StateGlyph(state: session.presentationState, size: 18)
            Text(session.project).font(MacTheme.font(12, .heavy)).foregroundStyle(MacTheme.ink)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Text(ToolActivity.label(for: session))
                Text("·").foregroundStyle(MacTheme.ink3)
                Text(session.updatedAt, style: .relative).monospacedDigit()
            }
            .font(MacTheme.font(10, .semibold)).foregroundStyle(MacTheme.ink2).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 4)
    }
}
