import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// Drives the menu bar: owns the server + store, polls for a snapshot, and
/// prepares the pairing QR. UI-facing state is published on the main actor.
@MainActor
final class MenuBarModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var pairing: PairingPayload?
    @Published private(set) var qrImage: NSImage?
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var glanceScale: CGFloat = 1.0

    let port: Int
    private let token: String
    private let store = SessionStore()
    private let approvalRegistry = ApprovalRegistry()
    private let notificationCoordinator: NotificationCoordinator
    private var pollTask: Task<Void, Never>?
    private var glance: GlanceWindow?

    init() {
        port = ProcessInfo.processInfo.environment["VIBEBUDDY_PORT"].flatMap(Int.init) ?? 9876
        // File-based store (owner-only): no Keychain ACL, so an ad-hoc rebuild
        // never re-prompts. Shared with vibebuddyd's default store.
        token = (try? TokenStore.defaultStore().loadOrCreate()) ?? Token.generate()
        let saved = UserDefaults.standard.double(forKey: "glanceScale")
        let base: CGFloat = saved > 0 ? saved : Self.defaultGlanceScale()
        // Snap to one of the 3 presets so the menu Picker selection always matches.
        glanceScale = [0.8, 1.0, 1.2].min(by: { abs($0 - base) < abs($1 - base) }) ?? 1.0
        let notifier = UserNotificationsNotifier()
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
            self.glance = GlanceWindow(model: self)
        }
    }

    var needsResponse: Int { sessions.lazy.filter { $0.status == .needsResponse }.count }
    var working: Int { sessions.lazy.filter { $0.status == .working }.count }
    var done: Int { sessions.lazy.filter { $0.status == .done }.count }

    private func startServer() {
        let pusher = APNsConfig.load().flatMap { try? APNsPusher(config: $0) }
        let server = VibeBuddyServer(store: store, token: token, port: port,
                                     pusher: pusher, approvalRegistry: approvalRegistry)
        Task.detached(priority: .utility) {
            do { try await server.buildApplication().runService() }
            catch { FileHandle.standardError.write(Data("server error: \(error)\n".utf8)) }
        }
    }

    private func preparePairing() {
        let host = LANAddress.primaryIPv4() ?? "127.0.0.1"
        let payload = Pairing.payload(host: host, port: port, token: token)
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
                self.notificationCoordinator.observe(snapshot.sessions)
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

    deinit { pollTask?.cancel() }
}
