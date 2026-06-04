import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

struct PairedPhone: Codable, Equatable {
    var name: String
    var model: String?
    var systemVersion: String?
    var lastSeen: Date
    var pushRegistered: Bool

    var subtitle: String {
        [model, systemVersion].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }
}

/// Drives the menu bar: owns the server + store, polls for a snapshot, and
/// prepares the pairing QR. UI-facing state is published on the main actor.
@MainActor
final class MenuBarModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var pairing: PairingPayload?
    @Published private(set) var qrImage: NSImage?
    /// The most-recently paired phone's display metadata (persisted), shown in the UI.
    @Published private(set) var pairedPhone: PairedPhone?
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var glanceScale: CGFloat = 1.0
    @Published var showGlance: Bool = true
    @Published var glanceExpanded: Bool = false
    @Published var openDashboardHotkey: Hotkey = .openDashboardDefault

    let port: Int
    private let token: String
    private let store = SessionStore()
    private let approvalRegistry = ApprovalRegistry()
    private let notifier = UserNotificationsNotifier()
    private let notificationCoordinator: NotificationCoordinator
    private var pollTask: Task<Void, Never>?
    private var glance: GlanceWindow?
    private static let pairedPhoneInfoKey = "pairedPhoneInfo"
    private static let legacyPairedPhoneKey = "pairedPhone"

    init() {
        port = ProcessInfo.processInfo.environment["VIBEBUDDY_PORT"].flatMap(Int.init) ?? 9876
        // File-based store (owner-only): no Keychain ACL, so an ad-hoc rebuild
        // never re-prompts. Shared with vibebuddyd's default store.
        token = (try? TokenStore.defaultStore().loadOrCreate()) ?? Token.generate()
        let saved = UserDefaults.standard.double(forKey: "glanceScale")
        let base: CGFloat = saved > 0 ? saved : Self.defaultGlanceScale()
        // Snap to one of the 3 presets so the menu Picker selection always matches.
        glanceScale = [0.8, 1.0, 1.2].min(by: { abs($0 - base) < abs($1 - base) }) ?? 1.0
        showGlance = Self.loadBool("showGlance", default: true)
        openDashboardHotkey = Hotkey.loadOpenDashboard()
        pairedPhone = Self.loadPairedPhone()
        notifier.requestAuthorization()
        notificationCoordinator = NotificationCoordinator(notifier: notifier)
        startServer()
        preparePairing()
        startPolling()
        // Create the glance on the next main-runloop tick — NOT synchronously here.
        // Hosting/displaying a SwiftUI view that observes `self` while `init` is
        // still running trips an AttributeGraph precondition (NSHostingView.layout
        // → ViewGraph update on a half-initialized ObservableObject).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }            // throwaway @StateObject probe deallocated
            guard self.glance == nil else { return }  // create the glance exactly once
            guard self.showGlance else { return }     // honor the Settings toggle at launch
            self.glance = GlanceWindow(model: self)
        }
    }

    /// A Bool default that treats an absent key as `default` (so first launch is on).
    private static func loadBool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
    }

    var needsResponse: Int { sessions.lazy.filter { $0.status == .needsResponse }.count }
    var working: Int { sessions.lazy.filter { $0.status == .working }.count }
    var done: Int { sessions.lazy.filter { $0.status == .done }.count }
    var macDisplayName: String { Self.localMacName() }
    var pairingAddress: String {
        guard let pairing else { return "Not ready" }
        return "\(pairing.host):\(pairing.port)"
    }

    private func startServer() {
        let pusher = APNsConfig.load().flatMap { try? APNsPusher(config: $0) }
        let server = VibeBuddyServer(store: store, token: token, port: port,
                                     pusher: pusher, approvalRegistry: approvalRegistry,
                                     onDevicePaired: { [weak self] device in
                                         Task { @MainActor in self?.recordPairedDevice(device) }
                                     })
        Task.detached(priority: .utility) {
            do { try await server.buildApplication().runService() }
            catch { FileHandle.standardError.write(Data("server error: \(error)\n".utf8)) }
        }
    }

    private func preparePairing() {
        let host = LANAddress.primaryIPv4() ?? "127.0.0.1"
        let payload = Pairing.payload(host: host, port: port, token: token, macName: macDisplayName)
        pairing = payload
        if let cg = Pairing.qrImage(from: Pairing.qrJSONString(for: payload)) {
            qrImage = NSImage(cgImage: cg, size: NSSize(width: 220, height: 220))
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.store.snapshot(now: Date())
                self.sessions = snapshot.sessions
                self.notificationCoordinator.observe(
                    snapshot.sessions,
                    appActive: NSApp.isActive,                                   // user looking at VibeBuddy?
                    quietMode: UserDefaults.standard.bool(forKey: "quietMode"))  // Focus mode → approvals only
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Resolve a pending approval from the Mac (Dashboard buttons / shortcuts).
    func decide(_ approvalId: String, approve: Bool) {
        Task { await approvalRegistry.resolve(id: approvalId, with: approve ? .allow : .deny) }
    }

    func jump(_ session: AgentSession) {
        guard let ref = session.terminalRef else { return }
        TerminalJumper.jump(ref)
    }

    static func defaultGlanceScale() -> CGFloat {
        let w = NSScreen.main?.frame.width ?? 1512
        return w >= 2000 ? 1.0 : 0.8        // iMac → Medium, MacBook → Small; pick Large for bigger
    }

    func setGlanceScale(_ s: CGFloat) {
        glanceScale = s
        UserDefaults.standard.set(Double(s), forKey: "glanceScale")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.set(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func setPairedPhone(_ name: String) {
        recordPairedDevice(DeviceRegistrationPayload(name: name))
    }

    func recordPairedDevice(_ device: DeviceRegistrationPayload) {
        let current = pairedPhone
        let next = PairedPhone(
            name: Self.nonEmpty(device.name) ?? current?.name ?? "iPhone",
            model: Self.nonEmpty(device.model) ?? current?.model,
            systemVersion: Self.nonEmpty(device.systemVersion) ?? current?.systemVersion,
            lastSeen: Date(),
            pushRegistered: current?.pushRegistered == true || device.hasPushToken
        )
        guard next != pairedPhone else { return }
        // A different (or first) phone pairing is the pair_success moment; the
        // same phone merely reconnecting (only `lastSeen`/push changed) is not.
        let isNewPhone = current == nil || current?.name != next.name
        pairedPhone = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.pairedPhoneInfoKey)
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyPairedPhoneKey)
        if isNewPhone { notifier.confirmPairing(deviceName: next.name) }
    }

    func forgetPairedPhone() {
        pairedPhone = nil
        UserDefaults.standard.removeObject(forKey: Self.pairedPhoneInfoKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyPairedPhoneKey)
    }

    func setShowGlance(_ on: Bool) {
        showGlance = on
        UserDefaults.standard.set(on, forKey: "showGlance")
        if on {
            if glance == nil { glance = GlanceWindow(model: self) } else { glance?.show() }
        } else {
            glance?.hide()
        }
    }

    func setGlanceExpanded(_ expanded: Bool) {
        guard expanded != glanceExpanded else { return }
        glanceExpanded = expanded
    }

    func setHotkey(_ hotkey: Hotkey) {
        openDashboardHotkey = hotkey
        hotkey.saveAsOpenDashboard()
        GlobalHotkey.setHotkey(hotkey)
    }

    private static func loadPairedPhone() -> PairedPhone? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: pairedPhoneInfoKey),
           let phone = try? JSONDecoder().decode(PairedPhone.self, from: data) {
            return phone
        }
        if let legacyName = defaults.string(forKey: legacyPairedPhoneKey), !legacyName.isEmpty {
            return PairedPhone(name: legacyName, model: nil, systemVersion: nil,
                               lastSeen: Date(), pushRegistered: false)
        }
        return nil
    }

    private static func localMacName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    deinit { pollTask?.cancel() }
}
