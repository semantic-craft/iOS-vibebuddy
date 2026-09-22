import AppKit
import Combine

/// Repairs the saved placement of the app's single SwiftUI MenuBarExtra.
/// AppKit's preference key is an implementation detail, isolated here: if it
/// disappears, leave placement to macOS. Never edit other apps' status items.
@MainActor
public final class MenuBarPlacementRecovery: NSObject, ObservableObject {
    public static let autosaveName = "VibeBuddy.MainMenu"
    public static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    private weak var statusItem: NSStatusItem?
    private let defaults: UserDefaults
    private let enabled: Bool

    public init(enabled: Bool, defaults: UserDefaults = .standard) {
        self.enabled = enabled
        self.defaults = defaults
        super.init()
        guard enabled else { return }
        // Before MenuBarExtra is constructed, so it restores the repaired value.
        if defaults.object(forKey: Self.positionKey) == nil,
           let legacy = defaults.object(forKey: "NSStatusItem Preferred Position Item-0") as? NSNumber {
            defaults.set(legacy, forKey: Self.positionKey)
        }
        repairSavedPosition()
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Distances are measured from the right edge, not global desktop origins.
    /// The caller supplies the hosting display first; a smaller secondary
    /// display must not invalidate a placement on a larger primary display.
    /// Missing geometry during a display transition is not evidence of corruption.
    public static func replacement(saved: Double?, widths: [Double]) -> Double? {
        guard let saved, let width = widths.first(where: { $0.isFinite && $0 > 0 }),
              !saved.isFinite || saved < 0 || saved >= width else { return nil }
        return min(180, width / 4)
    }

    private func replacement() -> Double? {
        guard let saved = defaults.object(forKey: Self.positionKey) as? NSNumber else { return nil }
        return Self.replacement(saved: saved.doubleValue,
            widths: [statusItem?.button?.window?.screen ?? NSScreen.screens.first]
                .compactMap { $0.map { Double($0.frame.width) } })
    }

    private func repairSavedPosition() {
        if let position = replacement() { defaults.set(position, forKey: Self.positionKey) }
    }

    /// Called by MenuBarExtraAccess after SwiftUI creates the real item.
    /// SwiftUI remains its only owner; this controller never creates another.
    public func attach(_ item: NSStatusItem) {
        guard enabled, statusItem !== item else { return }
        statusItem = item
        repairSavedPosition()
        item.autosaveName = Self.autosaveName
    }

    @objc private func displaysChanged() {
        // AppKit owns live display reflow. Validate the saved position for its
        // next restoration; do not remove an item owned by SwiftUI.
        guard enabled else { return }
        repairSavedPosition()
    }
}

/// The menu-bar icon is on unless the owner turned it off in Settings. macOS
/// also drives `MenuBarExtra(isInserted:)` — a ⌘-drag off the bar, or the
/// system dropping the item when the bar is crowded — and that write must not
/// become a saved "off": the icon would then stay gone across launches with
/// nothing on screen to bring it back (observed on the owner's Mac 2026-09-22).
public enum MenuBarIconVisibility {
    /// What to persist after the status item's insertion binding is written:
    /// an insertion is always kept; a removal keeps whatever Settings chose.
    public static func persisted(afterBindingWrite inserted: Bool, current: Bool) -> Bool {
        inserted ? true : current
    }
}
