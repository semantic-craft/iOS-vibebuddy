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
        // Read-aloud used to be Qwen-only; move its saved model and voice onto the
        // per-provider keys before any view reads them. Idempotent.
        VoiceSettings.migrateLegacyReadAloudKeys()
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
    private static let openDashboardNotification = Notification.Name(E2ERunConfiguration.current.map { "com.vibebuddy.e2e.\($0.id).openDashboard" } ?? "com.vibebuddy.mac.openDashboard")
    nonisolated(unsafe) private static var lock: SingleInstanceLock?

    static let role: Role = {
        let run = E2ERunConfiguration.current
        if run == nil && ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" { return .primary }
        do {
            if let acquired = try SingleInstanceLock.acquire(lockFileURL: try SingleInstanceLock.defaultLockFileURL()) {
                lock = acquired
                return .primary
            }
            return .secondary
        } catch {
            if run != nil { fatalError("E2E instance lock failed; refusing to start.") }
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

/// A stable launcher; task status is opt-in to avoid repeating the Glance.
/// Hiding the label cannot disconnect app commands.
struct MenuBarLabel: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("showMenuBarTaskStatus") private var showTaskStatus = false

    var body: some View {
        let state = model.presentationSummary.primaryState
        let count = model.presentationSummary.count(for: state)
        HStack(spacing: 3) {
            CatHeadIcon()
                .frame(width: 17, height: 17)
                .overlay(alignment: .topTrailing) {
                    if showTaskStatus && state != .unassigned {
                        TaskStatusIndicator(state, size: 6)
                            .offset(x: 1.5, y: -0.5)
                    }
                }
            if showTaskStatus && count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showTaskStatus && count > 0
            ? "VibeBuddy, \(count) \(state.label)" : "VibeBuddy")
        .help("Open VibeBuddy menu")
    }
}

private struct SessionListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Gives the scroller an explicit proposal even while MenuBarExtra asks for
/// an intrinsic size. Header and footer keep their natural height.
///
/// `sizeThatFits` deliberately ignores the proposed height and answers with the
/// height the panel *wants*, capped by `maximumHeight`. The menu-bar window
/// probes with a zero height and then re-asks with whatever height it currently
/// has; sizing to the proposal makes every answer agree with the question, so
/// the panel latches onto the first probe (a 1pt list) and can never grow back.
/// Only `placeSubviews` shrinks to the height actually granted.
private struct MenuPanelLayout: Layout {
    var maximumHeight: CGFloat
    var listHeight: CGFloat
    private let spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 356
        let heights = heights(width: width, budget: maximumHeight, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * 2)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = heights(width: bounds.width, budget: bounds.height, subviews: subviews)
        var y = bounds.minY
        for (view, height) in zip(subviews, heights) {
            view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }

    private func heights(width: CGFloat, budget rawBudget: CGFloat, subviews: Subviews) -> [CGFloat] {
        let natural = ProposedViewSize(width: width, height: nil)
        let header = subviews[0].sizeThatFits(natural).height
        let footer = subviews[2].sizeThatFits(natural).height
        let budget = min(maximumHeight, rawBudget)
        let available = max(1, budget - header - footer - spacing * 2)
        return [header, min(max(listHeight, 1), available), footer]
    }
}

/// `MenuBarExtra(.window)` aligns either panel edge with the status item.
/// Re-anchor it on the item's centre, clamped to the screen it is shown on.
private struct MenuPanelAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.realign() }

    final class AnchorView: NSView {
        private weak var statusItemWindow: NSWindow?
        private var isRealigning = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            for name: NSNotification.Name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(realign),
                                                       name: name, object: nil)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            statusItemWindow = nil
            realign()
        }

        /// Keep the item identity after centring changes the panel's left edge.
        /// Moving the panel posts another notification synchronously.
        @objc func realign() {
            guard !isRealigning, let window, let screen = hostScreen(for: window),
                  let item = anchoringStatusItem(for: window, on: screen) else { return }
            isRealigning = true
            defer { isRealigning = false }
            let x = MenuPanelPlacement.x(itemMidX: item.frame.midX,
                                         panelWidth: window.frame.width,
                                         visible: screen.visibleFrame)
            guard abs(x - window.frame.minX) > 0.5 else { return }
            window.setFrameOrigin(CGPoint(x: x, y: window.frame.minY))
        }

        /// The panel's own `screen` flips to the display above the moment its top
        /// edge meets the menu bar, so clamp against the display its body sits on.
        private func hostScreen(for panel: NSWindow) -> NSScreen? {
            let body = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
            return NSScreen.screens.first { $0.frame.contains(body) } ?? panel.screen
        }

        private func anchoringStatusItem(for panel: NSWindow, on screen: NSScreen) -> NSWindow? {
            // AppKit initially aligns either edge: the right edge when a panel
            // would overflow on the right. Reuse the identified live window
            // for later resizes and status-item movement, but
            // rediscover it when this view attaches to another panel or display.
            func isOnScreen(_ item: NSWindow) -> Bool {
                screen.frame.contains(CGPoint(x: item.frame.midX, y: item.frame.midY))
            }
            if let statusItemWindow, isOnScreen(statusItemWindow) { return statusItemWindow }
            statusItemWindow = NSApp.windows.first {
                $0.className == "NSStatusBarWindow" && isOnScreen($0)
                    && (abs($0.frame.minX - panel.frame.minX) < 1
                        || abs($0.frame.maxX - panel.frame.maxX) < 1)
            }
            return statusItemWindow
        }
    }
}

/// Reads the screen hosting this menu, rather than assuming the main display.
private struct MenuScreenReader: NSViewRepresentable {
    var onChange: (CGSize) -> Void

    func makeNSView(context: Context) -> ScreenView { ScreenView() }
    func updateNSView(_ view: ScreenView, context: Context) {
        view.onChange = onChange
        view.reportScreen()
    }

    final class ScreenView: NSView {
        var onChange: ((CGSize) -> Void)?
        private var lastSize: CGSize?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            NotificationCenter.default.addObserver(self, selector: #selector(reportScreen),
                                                   name: NSWindow.didChangeScreenNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(reportScreen),
                                                   name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reportScreen() }

        @objc func reportScreen() {
            guard let size = window?.screen?.visibleFrame.size, size != lastSize else { return }
            lastSize = size
            DispatchQueue.main.async { [weak self] in self?.onChange?(size) }
        }
    }
}

/// One control in the panel's footer row: an icon, an optional label and an
/// optional trailing shortcut hint. `showsLabel == false` is the narrow form —
/// the tooltip carries the name and the shortcut in every form, so the row can
/// shed text without leaving a control unexplained.
private struct MenuFooterControl: View {
    let label: LocalizedStringKey
    let systemImage: String
    let shortcut: String
    let tooltip: LocalizedStringKey
    /// The label this control shows in its *other* state. Laid out hidden
    /// underneath, so a control whose wording changes keeps one width and the
    /// row around it cannot re-fit itself every time the state flips.
    var alternateLabel: LocalizedStringKey?
    /// Read out after the label by VoiceOver — the Glance toggle's on/off state.
    var state: LocalizedStringKey?
    /// Combined with ⌘. Only Settings binds one here; Dashboard and Glance are
    /// global hotkeys registered by `GlobalHotkey`, not panel shortcuts.
    var keyEquivalent: KeyEquivalent?
    var showsLabel = true
    var showsShortcut = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 12))
                if showsLabel {
                    ZStack(alignment: .leading) {
                        if let alternateLabel { Text(alternateLabel).hidden() }
                        Text(label)
                    }
                    .fixedSize()
                    if showsShortcut && !shortcut.isEmpty {
                        Text(verbatim: shortcut)
                            .font(MacTheme.mono(9))
                            .foregroundStyle(MacTheme.ink3)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(keyEquivalent.map { KeyboardShortcut($0, modifiers: .command) })
        .help(tooltip)
        .accessibilityLabel(label)
        .accessibilityValue(state ?? "")
    }
}

/// The menu-bar dropdown: a command row you can type into, a one-line summary
/// of the whole snapshot, whatever needs a person pinned at the top, and the
/// rest as a stream of what just happened.
struct MenuContent: View {
    @ObservedObject var model: MenuBarModel
    @State private var listContentHeight: CGFloat = 120
    @State private var screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 800, height: 600)
    @State private var showsPhoneDetails = false
    @State private var hoveredSessionID: String?
    /// Which groups the user has folded away, by `MenuFeed.Section.Kind`. A
    /// search reopens all of them: a match must never hide inside a fold.
    /// Older work starts folded: it is there to be found, not to be read past.
    @State private var collapsed: Set<String> = [MenuFeed.Section.Kind.older.rawValue]
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The panel's own width, and the list's ceiling before it scrolls.
    private static let width: CGFloat = 360
    /// Two-line rows need more room than the old feed's single lines did; past
    /// this the list scrolls under the summary.
    private static let listCeiling: CGFloat = 320

    private var feed: MenuFeed { MenuFeed(model.sessions, query: query) }

    var body: some View {
        let feed = self.feed
        return MenuPanelLayout(maximumHeight: max(1, screenSize.height - 48),
                               listHeight: min(listContentHeight, Self.listCeiling)) {
            VStack(spacing: 0) {
                commandRow(feed)
                MenuHairline()
                // The summary steps aside for the result band while you type:
                // one line at the top of the list, never two.
                if feed.emptyState == nil {
                    if feed.query.isEmpty { summaryRow(feed.summary) } else { resultBand(feed) }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: feed.query.isEmpty)
            sessionList(feed)
            VStack(spacing: 0) {
                MenuHairline()
                controlRow
                    .padding(.horizontal, 9)
                    .padding(.top, 6)
                    .padding(.bottom, 7)
            }
        }
        .frame(width: min(Self.width, screenSize.width - 24))
        .background(MacTheme.bg)
        .background(MenuScreenReader { screenSize = $0 })
        .background(MenuPanelAnchor())
        // Typing is the only way to narrow the list, so the field takes the
        // caret as the panel opens and each open starts from the whole snapshot.
        .onAppear {
            query = ""
            searchFocused = true
        }
        .onChange(of: query) { old, new in
            if old.isEmpty, !new.isEmpty { collapsed.removeAll() }
        }
    }

    private var phoneDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Phone details").font(MacTheme.font(13, .semibold))
                    Spacer()
                    Button("Done") { showsPhoneDetails = false }
                        .keyboardShortcut(.cancelAction)
                }
                if let phone = model.pairedPhone {
                    Text(phone.confirmed ? String(localized: "Paired: \(phone.name)") : String(localized: "Registered: \(phone.name)"))
                    if !phone.subtitle.isEmpty { Text(phone.subtitle) }
                    Text("Last seen \(phone.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                    Text(phone.pushRegistered ? "Push registered" as LocalizedStringKey : "Push not registered")
                } else {
                    Text("No phone paired")
                }
                Text("Live connection status unavailable")
                    .foregroundStyle(MacTheme.ink2)
                Text("Push registration does not confirm notification delivery.")
                    .foregroundStyle(MacTheme.ink2)
                Divider()
                TailscalePairingSettings(model: model)
                Text(model.pairingAddress).font(MacTheme.mono(11)).textSelection(.enabled)
                Button(model.pairingInProgress ? "Cancel pairing" : "Pair a phone") {
                    if model.pairingInProgress { model.endPairing() } else { model.beginPairing() }
                }
                .disabled(model.changingPairing || (!model.pairingInProgress && model.pairing == nil))
                if model.pairingInProgress, let qr = model.qrImage {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .scaledToFit().frame(width: 176, height: 176)
                        .padding(12).background(.white)
                        .accessibilityLabel("Pairing QR code")
                    Text("Scan this in the vibebuddy iOS app within 2 minutes.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
        }
        .frame(width: min(320, screenSize.width - 48), height: min(430, screenSize.height - 72))
        .font(MacTheme.font(12))
        .foregroundStyle(MacTheme.ink)
        .background(MacTheme.bg)
    }

    /// Every way out of the panel, on one clickable row: Dashboard, the Glance
    /// toggle and Settings on the left; phone state and the overflow menu on
    /// the right. Nothing here is reachable only by shortcut.
    ///
    /// The row must never wrap or grow taller than one line, so it sheds
    /// detail instead, cheapest first: the shortcut hints, then the phone's
    /// name (its dot still shows the pairing state, and the tooltip the name),
    /// and only then the three labels. Which form is used depends on the panel
    /// width and on how long the user's own hotkeys render — the
    /// Open-Dashboard default is a five-glyph Hyper chord, so at 380pt the
    /// hints usually do not fit and the tooltips carry them instead.
    private var controlRow: some View {
        ViewThatFits(in: .horizontal) {
            controlRowBody(showsLabels: true, showsShortcuts: true, showsPhoneName: true)
            controlRowBody(showsLabels: true, showsShortcuts: true, showsPhoneName: false)
            controlRowBody(showsLabels: true, showsShortcuts: false, showsPhoneName: true)
            controlRowBody(showsLabels: true, showsShortcuts: false, showsPhoneName: false)
            controlRowBody(showsLabels: false, showsShortcuts: false, showsPhoneName: true)
            controlRowBody(showsLabels: false, showsShortcuts: false, showsPhoneName: false)
        }
        .font(MacTheme.font(11))
        .foregroundStyle(MacTheme.ink)
        .popover(isPresented: $showsPhoneDetails, arrowEdge: .trailing) {
            phoneDetails
        }
    }

    private func controlRowBody(showsLabels: Bool, showsShortcuts: Bool, showsPhoneName: Bool) -> some View {
        HStack(spacing: 2) {
            MenuFooterControl(
                label: "Dashboard",
                systemImage: "macwindow",
                shortcut: model.openDashboardHotkey.displayString,
                tooltip: "Open Dashboard · \(model.openDashboardHotkey.displayString)",
                showsLabel: showsLabels,
                showsShortcut: showsShortcuts) {
                    NotificationCenter.default.post(name: .openDashboard, object: nil)
                }
            MenuFooterControl(
                label: model.showGlance ? "Hide Glance" : "Glance",
                systemImage: model.showGlance ? "eye.slash" : "eye",
                shortcut: model.toggleGlanceHotkey.displayString,
                tooltip: "Toggle Glance · \(model.toggleGlanceHotkey.displayString)",
                alternateLabel: model.showGlance ? "Glance" : "Hide Glance",
                state: model.showGlance ? "Showing" : "Hidden",
                showsLabel: showsLabels,
                showsShortcut: showsShortcuts) {
                    model.setShowGlance(!model.showGlance)
                }
            MenuFooterControl(
                label: "Settings",
                systemImage: "gearshape",
                shortcut: "⌘,",
                tooltip: "Settings · ⌘,",
                keyEquivalent: ",",
                showsLabel: showsLabels,
                showsShortcut: showsShortcuts) {
                    NotificationCenter.default.post(name: .openAppSettings, object: nil)
                }
            Spacer(minLength: 6)
            phoneControl(showsName: showsPhoneName)
            moreMenu
        }
    }

    /// Phone state, where the standalone `Paired: … · Last seen …` row used to
    /// be. It opens the same pairing detail popover, QR code included.
    private func phoneControl(showsName: Bool) -> some View {
        let phone = model.pairedPhone
        return Button { showsPhoneDetails.toggle() } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(phone == nil ? MacTheme.ink3 : MacTheme.accent)
                    .frame(width: 6, height: 6)
                if showsName {
                    Text(phone?.name ?? String(localized: "No phone paired"))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(MacTheme.ink2)
        .help(Self.phoneTooltip(phone))
        .accessibilityLabel("Phone details and pairing")
        .accessibilityValue(phone.map { $0.confirmed ? String(localized: "Paired: \($0.name)") : String(localized: "Registered: \($0.name)") }
                             ?? String(localized: "No phone paired"))
    }

    /// Both branches stay string literals so the translation keeps its `%@`.
    private static func phoneTooltip(_ phone: PairedPhone?) -> LocalizedStringKey {
        guard let phone else { return "No phone paired" }
        return phone.confirmed ? "Paired: \(phone.name)" : "Registered: \(phone.name)"
    }

    private var moreMenu: some View {
        Menu {
            Button("Check for Updates…") {
                NSApp.activate(ignoringOtherApps: true)
                Updater.shared.checkForUpdates()
            }
            Button("Quit vibebuddy") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(MacTheme.ink2)
        .help("More")
        .accessibilityLabel("More")
    }

    // MARK: - The command row

    /// One field, with the voice companion on its left and the shortcut badge on
    /// its right. The cat left this row with ADR-0015: the mic is the voice
    /// entry point here, and the panel's status light is the dot on the summary
    /// line under it.
    private func commandRow(_ feed: MenuFeed) -> some View {
        HStack(spacing: 9) {
            MenuCircleButton(systemName: voiceGlyph,
                             tint: voiceIsIdle ? MacTheme.ink2 : .white,
                             ground: voiceIsIdle ? MacTheme.bg3 : MacTheme.accent) {
                model.voiceChat.toggle()
            }
            .help(voiceIsIdle ? "Start voice conversation" : "End voice conversation")
            .accessibilityLabel("Toggle voice companion")

            TextField(text: $query) { Text("Search sessions or run a command") }
                .textFieldStyle(.plain)
                .font(MacTheme.font(13.5))
                .foregroundStyle(MacTheme.ink)
                .focused($searchFocused)
                .onSubmit { jumpToTopResult(feed) }
                .accessibilityLabel("Search sessions")

            Button { searchFocused = true } label: {
                Text(verbatim: "⌘K")
                    .font(MacTheme.mono(9.5))
                    .foregroundStyle(MacTheme.ink2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(MacTheme.bg3, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .help("Search sessions")
            .accessibilityLabel("Search sessions")
        }
        .padding(.horizontal, MenuMetrics.gutter)
        .padding(.vertical, 10)
    }

    private var voiceIsIdle: Bool { model.voiceChat.phase == .idle }

    /// The mic tells you which half of the conversation is live, as the cat's
    /// face used to.
    private var voiceGlyph: String {
        switch model.voiceChat.phase {
        case .idle: "mic"
        case .listening: "mic.fill"
        case .speaking: "waveform"
        case .connecting, .recovering, .thinking: "ellipsis"
        }
    }

    /// Return, while searching, goes to the row the `↵ jump` badge marks.
    private func jumpToTopResult(_ feed: MenuFeed) {
        guard !feed.query.isEmpty, let target = feed.topResult else { return }
        model.jump(target)
    }

    // MARK: - Summary and result band

    /// One line for the whole snapshot, led by the panel's status light: the
    /// most urgent state present, which keeps telling the truth while a query
    /// narrows the list below. It sits above the scroller rather than inside
    /// it, so a long list scrolls under an answer that stays put.
    private func summaryRow(_ summary: TaskPresentationSummary) -> some View {
        let rest = MacSummaryCopy.restLine(summary)
        return HStack(spacing: 7) {
            statusDot(summary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(MacSummaryCopy.moodLine(summary))
                    .font(MacTheme.font(12.5, .semibold))
                    .foregroundStyle(MacTheme.ink)
                if !rest.isEmpty {
                    Text(verbatim: "· \(rest)")
                        .font(MacTheme.font(11.5))
                        .foregroundStyle(MacTheme.ink2)
                }
                Spacer(minLength: 0)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, MenuMetrics.gutter)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusDot(_ summary: TaskPresentationSummary) -> some View {
        let state = summary.primaryState
        if state != .unassigned {
            Circle()
                .fill(MacTheme.status(state))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
    }

    /// What the query hid, said out loud — otherwise filtering something away
    /// looks like it stopped existing.
    private func resultBand(_ feed: MenuFeed) -> some View {
        let needs = MacSummaryCopy.needsYou(feed.summary)
        return HStack(spacing: 7) {
            Text("\(feed.matchCount) of \(feed.totalCount)")
                .font(MacTheme.font(10.5, .semibold))
                .foregroundStyle(MacTheme.ink)
                .monospacedDigit()
                .fixedSize()
            Text("· matching “\(feed.query)”")
                .font(MacTheme.font(10.5))
                .foregroundStyle(MacTheme.ink2)
                .lineLimit(1)
            Spacer(minLength: 6)
            if needs > 0 {
                Text("\(needs) still need you")
                    .font(MacTheme.font(10.5, .semibold))
                    .foregroundStyle(MacTheme.status(.requiresInput))
                    .fixedSize()
            }
        }
        .padding(.horizontal, MenuMetrics.gutter)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.bg2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - The list

    private func sessionList(_ feed: MenuFeed) -> some View {
        ScrollView(.vertical) {
            listContent(feed)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: SessionListHeightKey.self, value: geo.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(SessionListHeightKey.self) { height in
            // Ignore transient zero measurements during snapshot replacement.
            if height > 0 { listContentHeight = height }
        }
    }

    /// The list (ADR-0015): the Companion's three attention groups, each
    /// collapsible, with hairlines between rows. A group that holds nothing is
    /// absent, not empty, so the panel shortens.
    @ViewBuilder
    private func listContent(_ feed: MenuFeed) -> some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            if let empty = feed.emptyState {
                emptyState(empty)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(feed.sections) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            MenuSectionHeader(title: Self.groupTitle(section.kind),
                                              count: section.sessions.count,
                                              expanded: expansion(section.kind))
                            if !collapsed.contains(section.kind.rawValue) {
                                ForEach(Array(section.sessions.enumerated()), id: \.element.id) { index, session in
                                    row(session, feed: feed, now: now,
                                        showsHairline: index < section.sessions.count - 1)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func groupTitle(_ kind: MenuFeed.Section.Kind) -> LocalizedStringKey {
        switch kind {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .older: "Older"
        }
    }

    private func expansion(_ kind: MenuFeed.Section.Kind) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(kind.rawValue) },
                set: { expand in
                    if expand { collapsed.remove(kind.rawValue) } else { collapsed.insert(kind.rawValue) }
                })
    }

    /// A flat row: a status dot, the session's title and how long ago it moved
    /// on the first line; what the agent is doing and its own sentence on the
    /// second. Hover fills the whole row — there is no card.
    private func row(_ session: AgentSession, feed: MenuFeed, now: Date,
                     showsHairline: Bool) -> some View {
        let isTarget = !feed.query.isEmpty && feed.topResult?.id == session.id
        return VStack(spacing: 0) {
            Button { model.jump(session) } label: {
                HStack(alignment: .top, spacing: 0) {
                    Circle()
                        .fill(MacTheme.status(session.presentationState))
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                        .frame(width: MenuMetrics.dotLane, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: session.displayTitle)
                                .font(MacTheme.font(12.5, .medium))
                                .foregroundStyle(MacTheme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if isTarget { jumpBadge }
                            Text(verbatim: MenuFeed.age(of: session.updatedAt, now: now))
                                .font(MacTheme.mono(9.5))
                                .monospacedDigit()
                                .foregroundStyle(MacTheme.ink3)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        activityLine(session)
                        if let outcome = model.jumpFeedback[session.id] {
                            Text(outcome.macMessage(for: session))
                                .font(MacTheme.font(10, .semibold))
                                .foregroundStyle(MacTheme.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.trailing, MenuMetrics.gutter)
                }
                .padding(.leading, MenuMetrics.gutter)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hoveredSessionID == session.id ? MacTheme.bg2 : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveredSessionID = $0 ? session.id : nil }
            .help("\(session.displayTitle)\n\(session.agent.displayName) · \(session.statusLabel)\n\(session.summary ?? "")")
            .accessibilityLabel(Text(verbatim: session.displayTitle))
            .accessibilityValue(Text(verbatim: session.summary ?? session.statusLabel))
            .accessibilityHint("Jump to this session")
            if showsHairline {
                MenuHairline(leading: MenuMetrics.gutter + MenuMetrics.dotLane)
            }
        }
    }

    /// What the agent is doing, in the state's own colour, then its own
    /// sentence. One line: the row's width is the budget.
    private func activityLine(_ session: AgentSession) -> some View {
        let activity = Text(LocalizedStringKey(ToolActivity.label(for: session)))
            .foregroundColor(MacTheme.status(session.presentationState))
        let detail = session.displaySummary.flatMap { $0.isEmpty ? nil : Text(verbatim: $0) }
        return (detail.map { activity + Text(verbatim: "  ") + $0.foregroundColor(MacTheme.ink2) } ?? activity)
            .font(MacTheme.font(11.5))
            .lineLimit(1)
    }

    private var jumpBadge: some View {
        Text(verbatim: "↵ jump")
            .font(MacTheme.mono(9))
            .foregroundStyle(MacTheme.ink2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(MacTheme.line, lineWidth: CompanionType.hairline))
            .fixedSize()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func emptyState(_ state: MenuFeed.EmptyState) -> some View {
        VStack(spacing: 5) {
            Image(systemName: Self.emptyGlyph(state))
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(MacTheme.ink3)
                .padding(.bottom, 7)
            switch state {
            case .noSessions:
                Text("No sessions reporting")
                    .font(MacTheme.font(13, .semibold))
                    .foregroundStyle(MacTheme.ink)
                Text("Start a turn or repair hooks in Settings.")
                    .font(MacTheme.font(11.5))
                    .foregroundStyle(MacTheme.ink2)
            case let .noMatches(query):
                Text("No matches for “\(query)”")
                    .font(MacTheme.font(13, .semibold))
                    .foregroundStyle(MacTheme.ink)
                    .lineLimit(2)
                Text("Try another word, or ⌘K for commands.")
                    .font(MacTheme.font(11.5))
                    .foregroundStyle(MacTheme.ink2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 30)
        .accessibilityElement(children: .combine)
    }

    private static func emptyGlyph(_ state: MenuFeed.EmptyState) -> String {
        switch state {
        case .noSessions: "moon.zzz"
        case .noMatches: "magnifyingglass"
        }
    }
}
