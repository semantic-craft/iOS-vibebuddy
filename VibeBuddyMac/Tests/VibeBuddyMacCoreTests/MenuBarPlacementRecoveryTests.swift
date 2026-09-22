import XCTest
@testable import VibeBuddyMacCore

final class MenuBarPlacementRecoveryTests: XCTestCase {
    @MainActor func testRestoredExternalDisplayPositionFitsLaptop() {
        XCTAssertEqual(MenuBarPlacementRecovery.replacement(saved: 2588, widths: [1710]), 180)
        XCTAssertNil(MenuBarPlacementRecovery.replacement(saved: 2588, widths: [3840, 1710]))
        XCTAssertNil(MenuBarPlacementRecovery.replacement(saved: 2588, widths: [3840]))
    }

    @MainActor func testPreservesUserPlacementAndWaitsForDisplayGeometry() {
        XCTAssertNil(MenuBarPlacementRecovery.replacement(saved: 180, widths: [1710]))
        XCTAssertNil(MenuBarPlacementRecovery.replacement(saved: nil, widths: [1710]))
        XCTAssertNil(MenuBarPlacementRecovery.replacement(saved: 2588, widths: []))
        XCTAssertEqual(MenuBarPlacementRecovery.replacement(saved: -1, widths: [600]), 150)
    }
    @MainActor func testMigrationAndSecondaryInstanceDoNotOverwritePreferences() {
        let name = "menu-placement-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(120, forKey: "NSStatusItem Preferred Position Item-0")
        defaults.set(false, forKey: "showMenuBarIcon")
        let secondary = MenuBarPlacementRecovery(enabled: false, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: MenuBarPlacementRecovery.positionKey))
        let first = MenuBarPlacementRecovery(enabled: true, defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: MenuBarPlacementRecovery.positionKey), 120)
        defaults.set(140, forKey: MenuBarPlacementRecovery.positionKey)
        let next = MenuBarPlacementRecovery(enabled: true, defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: MenuBarPlacementRecovery.positionKey), 140)
        XCTAssertFalse(defaults.bool(forKey: "showMenuBarIcon"))
        withExtendedLifetime((secondary, first, next)) {}
    }


    func testStatusItemRemovalDoesNotPersistAsHidden() {
        // Dragged off the bar / dropped by the system: the saved choice survives.
        XCTAssertTrue(MenuBarIconVisibility.persisted(afterBindingWrite: false, current: true))
        // Settings said off, and the system removed it: still off.
        XCTAssertFalse(MenuBarIconVisibility.persisted(afterBindingWrite: false, current: false))
        // Any insertion is an explicit on.
        XCTAssertTrue(MenuBarIconVisibility.persisted(afterBindingWrite: true, current: false))
        XCTAssertTrue(MenuBarIconVisibility.persisted(afterBindingWrite: true, current: true))
    }
}
