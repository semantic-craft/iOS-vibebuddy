import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("Hotkey — modifier conversion, display, persistence")
struct HotkeyTests {
    // NSEvent.ModifierFlags device-independent raw bits (so tests don't import AppKit).
    static let shift:   UInt = 1 << 17
    static let control: UInt = 1 << 18
    static let option:  UInt = 1 << 19
    static let command: UInt = 1 << 20
    // Carbon modifier masks (Carbon.HIToolbox Events.h).
    static let carbonCmd: UInt32 = 0x0100, carbonShift: UInt32 = 0x0200
    static let carbonOption: UInt32 = 0x0800, carbonControl: UInt32 = 0x1000

    @Test("Cocoa command flag converts to the Carbon command mask")
    func commandConverts() {
        let hk = Hotkey(keyCode: 2, cocoaModifiers: Self.command, displayKey: "D")
        #expect(hk.carbonModifiers == Self.carbonCmd)
    }

    @Test("the Hyper combo converts to all four Carbon masks")
    func hyperConverts() {
        let hyper = Self.control | Self.option | Self.shift | Self.command
        let hk = Hotkey(keyCode: 2, cocoaModifiers: hyper, displayKey: "D")
        #expect(hk.carbonModifiers == Self.carbonCmd | Self.carbonShift | Self.carbonOption | Self.carbonControl)
    }

    @Test("displayString shows modifiers in ⌃⌥⇧⌘ order then the key")
    func displayOrder() {
        let hyper = Self.control | Self.option | Self.shift | Self.command
        let hk = Hotkey(keyCode: 2, cocoaModifiers: hyper, displayKey: "D")
        #expect(hk.displayString == "⌃⌥⇧⌘D")
    }

    @Test("hasModifier is false for a bare key, true with any modifier")
    func hasModifier() {
        #expect(Hotkey(keyCode: 2, cocoaModifiers: 0, displayKey: "D").hasModifier == false)
        #expect(Hotkey(keyCode: 2, cocoaModifiers: Self.command, displayKey: "D").hasModifier == true)
    }

    @Test("the default Open-Dashboard hotkey is Hyper + '")
    func defaultIsHyperQuote() {
        let d = Hotkey.openDashboardDefault
        #expect(d.keyCode == 39)                        // kVK_ANSI_Quote
        #expect(d.displayString == "⌃⌥⇧⌘'")
        #expect(d.carbonModifiers == Self.carbonCmd | Self.carbonShift | Self.carbonOption | Self.carbonControl)
        #expect(d.hasModifier)
    }

    @Test("Codable round-trips")
    func codableRoundTrip() throws {
        let hk = Hotkey(keyCode: 2, cocoaModifiers: Self.command | Self.shift, displayKey: "D")
        let data = try JSONEncoder().encode(hk)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == hk)
    }

    @Test("load returns the default when nothing is saved, and the saved value after save")
    func persistenceRoundTrip() throws {
        let suite = "vb-hotkey-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(Hotkey.loadOpenDashboard(defaults) == .openDashboardDefault)

        let custom = Hotkey(keyCode: 2, cocoaModifiers: Self.command, displayKey: "D")
        custom.saveAsOpenDashboard(defaults)
        #expect(Hotkey.loadOpenDashboard(defaults) == custom)
    }
}
