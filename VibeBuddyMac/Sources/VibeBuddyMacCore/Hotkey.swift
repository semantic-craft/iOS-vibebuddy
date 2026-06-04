import Foundation

/// A global keyboard shortcut, stored as the virtual key code plus the
/// `NSEvent.ModifierFlags` raw value captured when recording. Kept pure
/// (Foundation-only, no AppKit/Carbon import) so the conversion and display
/// logic is unit-testable; the app target converts `carbonModifiers` into the
/// argument `RegisterEventHotKey` wants.
public struct Hotkey: Codable, Equatable, Sendable {
    public let keyCode: UInt32       // virtual key code (kVK_*)
    public let cocoaModifiers: UInt  // NSEvent.ModifierFlags rawValue (device-independent)
    public let displayKey: String    // human label for the key, e.g. "'", "D", "Space"

    public init(keyCode: UInt32, cocoaModifiers: UInt, displayKey: String) {
        self.keyCode = keyCode
        self.cocoaModifiers = cocoaModifiers
        self.displayKey = displayKey
    }

    // NSEvent.ModifierFlags device-independent raw bits.
    private static let cocoaShift:   UInt = 1 << 17
    private static let cocoaControl: UInt = 1 << 18
    private static let cocoaOption:  UInt = 1 << 19
    private static let cocoaCommand: UInt = 1 << 20
    // Carbon modifier masks (Carbon.HIToolbox Events.h).
    private static let carbonCmd:     UInt32 = 0x0100
    private static let carbonShift:   UInt32 = 0x0200
    private static let carbonOption:  UInt32 = 0x0800
    private static let carbonControl: UInt32 = 0x1000

    /// The modifier mask `RegisterEventHotKey` expects.
    public var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if cocoaModifiers & Self.cocoaCommand != 0 { m |= Self.carbonCmd }
        if cocoaModifiers & Self.cocoaShift   != 0 { m |= Self.carbonShift }
        if cocoaModifiers & Self.cocoaOption  != 0 { m |= Self.carbonOption }
        if cocoaModifiers & Self.cocoaControl != 0 { m |= Self.carbonControl }
        return m
    }

    /// True if at least one of ⌃⌥⇧⌘ is held — bare keys are rejected so a
    /// recorded shortcut can never swallow ordinary typing system-wide.
    public var hasModifier: Bool {
        cocoaModifiers & (Self.cocoaCommand | Self.cocoaShift | Self.cocoaOption | Self.cocoaControl) != 0
    }

    /// Menu-style rendering: modifier glyphs in ⌃⌥⇧⌘ order, then the key.
    public var displayString: String {
        var s = ""
        if cocoaModifiers & Self.cocoaControl != 0 { s += "⌃" }
        if cocoaModifiers & Self.cocoaOption  != 0 { s += "⌥" }
        if cocoaModifiers & Self.cocoaShift   != 0 { s += "⇧" }
        if cocoaModifiers & Self.cocoaCommand != 0 { s += "⌘" }
        return s + displayKey
    }

    /// Default Open-Dashboard shortcut: Hyper + ' (⌃⌥⇧⌘ + apostrophe).
    public static let openDashboardDefault = Hotkey(
        keyCode: 39,  // kVK_ANSI_Quote
        cocoaModifiers: cocoaControl | cocoaOption | cocoaShift | cocoaCommand,
        displayKey: "'")

    private static let storageKey = "openDashboardHotkey"

    /// The persisted Open-Dashboard shortcut, or the default if none/invalid.
    public static func loadOpenDashboard(_ defaults: UserDefaults = .standard) -> Hotkey {
        guard let data = defaults.data(forKey: storageKey),
              let hk = try? JSONDecoder().decode(Hotkey.self, from: data)
        else { return .openDashboardDefault }
        return hk
    }

    public func saveAsOpenDashboard(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Default Toggle-Glance shortcut: ⌥⌘G — a light two-key combo (the Hyper
    /// chord was awkward to press). Hides/shows the floating glance.
    public static let toggleGlanceDefault = Hotkey(
        keyCode: 5,  // kVK_ANSI_G
        cocoaModifiers: cocoaOption | cocoaCommand,
        displayKey: "G")

    private static let glanceStorageKey = "toggleGlanceHotkey"

    /// The persisted Toggle-Glance shortcut, or the default if none/invalid.
    public static func loadToggleGlance(_ defaults: UserDefaults = .standard) -> Hotkey {
        guard let data = defaults.data(forKey: glanceStorageKey),
              let hk = try? JSONDecoder().decode(Hotkey.self, from: data)
        else { return .toggleGlanceDefault }
        return hk
    }

    public func saveAsToggleGlance(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.glanceStorageKey)
        }
    }
}
