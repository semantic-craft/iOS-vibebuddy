import Carbon.HIToolbox
import AppKit

extension Notification.Name { static let openDashboard = Notification.Name("vibebuddy.openDashboard") }

/// Registers one system-wide hotkey (default ⌃⌥⇧⌘ + ', i.e. kVK_ANSI_Quote) and
/// posts `.openDashboard` when pressed. No Accessibility permission needed.
///
/// `@MainActor`-isolated: `install()` is only ever called from
/// `applicationDidFinishLaunching` (main actor), which keeps the mutable
/// `ref` / shared singleton concurrency-safe under Swift 6. The Carbon
/// callback captures nothing and only posts a notification (thread-safe).
@MainActor
final class GlobalHotkey {
    private var ref: EventHotKeyRef?
    private static let shared = GlobalHotkey()

    static func install() { shared.register() }

    private func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            NotificationCenter.default.post(name: .openDashboard, object: nil)
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x56424259), id: 1) // 'VBBY'
        let mods = UInt32(cmdKey | optionKey | shiftKey | controlKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_Quote), mods, id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}
