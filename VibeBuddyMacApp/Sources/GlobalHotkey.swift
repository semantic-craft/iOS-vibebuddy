import Carbon.HIToolbox
import AppKit
import VibeBuddyMacCore

extension Notification.Name { static let openDashboard = Notification.Name("vibebuddy.openDashboard") }

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
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    private static let shared = GlobalHotkey()

    /// Install the Carbon handler (once) and register the saved shortcut.
    static func install() { shared.start() }

    /// Re-register to a new shortcut (called by the Settings recorder).
    static func setHotkey(_ hotkey: Hotkey) { shared.register(hotkey) }

    private func start() {
        installHandlerIfNeeded()
        register(Hotkey.loadOpenDashboard())
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            NotificationCenter.default.post(name: .openDashboard, object: nil)
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    private func register(_ hotkey: Hotkey) {
        if let existing = ref { UnregisterEventHotKey(existing); ref = nil }
        let id = EventHotKeyID(signature: OSType(0x56424259), id: 1) // 'VBBY'
        RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}
