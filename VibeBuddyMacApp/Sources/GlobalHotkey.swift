import Carbon.HIToolbox
import AppKit
import VibeBuddyMacCore

extension Notification.Name {
    static let openDashboard = Notification.Name("vibebuddy.openDashboard")
    static let toggleGlance = Notification.Name("vibebuddy.toggleGlance")
}

/// Registers one system-wide hotkey and posts `.openDashboard` when pressed.
/// No Accessibility permission needed. The shortcut is user-configurable from
/// Settings: `install()` loads the saved `Hotkey` (default ⌃⌥⇧⌘ + '), and
/// `setHotkey(_:)` re-registers a new combo at runtime.
///
/// `@MainActor`-isolated: `install()`/`setHotkey(_:)` are only called from the
/// main actor (`applicationDidFinishLaunching`, the Settings recorder), keeping
/// the mutable `ref`/singleton concurrency-safe under Swift 6. The Carbon
/// callback captures nothing and only posts a notification (thread-safe).
@MainActor
final class GlobalHotkey {
    private var dashboardRef: EventHotKeyRef?
    private var glanceRef: EventHotKeyRef?
    private var handlerInstalled = false
    private static let shared = GlobalHotkey()

    private static let signature = OSType(0x56424259)   // 'VBBY'
    private static let dashboardID: UInt32 = 1
    private static let glanceID: UInt32 = 2

    /// Install the Carbon handler (once) and register the saved shortcuts.
    static func install() { shared.start() }

    /// Re-register the Open-Dashboard shortcut (called by the Settings recorder).
    static func setHotkey(_ hotkey: Hotkey) {
        shared.register(hotkey, id: dashboardID, ref: \.dashboardRef)
    }

    /// Re-register the Toggle-Glance shortcut.
    static func setGlanceHotkey(_ hotkey: Hotkey) {
        shared.register(hotkey, id: glanceID, ref: \.glanceRef)
    }

    private func start() {
        installHandlerIfNeeded()
        register(Hotkey.loadOpenDashboard(), id: Self.dashboardID, ref: \.dashboardRef)
        register(Hotkey.loadToggleGlance(), id: Self.glanceID, ref: \.glanceRef)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            // Distinguish which shortcut fired by its EventHotKeyID.
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let name: Notification.Name = hkID.id == GlobalHotkey.glanceID ? .toggleGlance : .openDashboard
            NotificationCenter.default.post(name: name, object: nil)
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    private func register(_ hotkey: Hotkey, id: UInt32, ref keyPath: ReferenceWritableKeyPath<GlobalHotkey, EventHotKeyRef?>) {
        if let existing = self[keyPath: keyPath] { UnregisterEventHotKey(existing); self[keyPath: keyPath] = nil }
        var newRef: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, hkID,
                            GetApplicationEventTarget(), 0, &newRef)
        self[keyPath: keyPath] = newRef
    }
}
