import Foundation
import XCTest
@testable import VibeBuddyKit

/// The Kit's string table resolves the shared copy in Chinese (ticket 08).
/// Opens the zh-Hans `.lproj` directly, so the assertions do not depend on the
/// machine's preferred languages.
final class KitLocalizationTests: XCTestCase {
    private var zhHans: Bundle {
        guard let bundle = KitLocalization.bundle(for: "zh-Hans") else {
            XCTFail("VibeBuddyKit has no zh-Hans.lproj"); return .main
        }
        return bundle
    }

    func testGroupNamesResolveInChinese() {
        XCTAssertEqual(zhHans.localizedString(forKey: "Needs you", value: nil, table: nil), "需要你")
        XCTAssertEqual(String(localized: "Needs you", bundle: zhHans), "需要你")
        XCTAssertEqual(String(localized: "Working", bundle: zhHans), "进行中")
        XCTAssertEqual(String(localized: "Done", bundle: zhHans), "完成")
    }

    func testInterpolatedKeysResolveInChinese() {
        // `\(n)` becomes `%lld` in the key; a literal `%` in the source becomes `%%`.
        XCTAssertEqual(String(localized: "\(3) things need you", bundle: zhHans), "3 件事需要你")
        XCTAssertEqual(String(localized: "\(32)% used", bundle: zhHans), "已用 32%")
        XCTAssertEqual(String(localized: "\(32)% used, \(55)% of the window elapsed", bundle: zhHans),
                       "已用 32%，窗口已过去 55%")
        XCTAssertEqual(String(localized: "use \("Grep")", bundle: zhHans), "使用 Grep")
    }

    func testNotificationCategoryTitlesResolveInChinese() {
        // LocalizedStringResource carries the Kit bundle, so a host app without
        // the key still gets the Chinese title.
        let title = NotificationCategory.needsApproval.categoryTitle
        XCTAssertEqual(title.key, "Permission requests")
        XCTAssertEqual(zhHans.localizedString(forKey: title.key, value: nil, table: nil), "权限请求")
        if case .atURL(let url) = title.bundle {
            XCTAssertEqual(url, KitLocalization.bundle.bundleURL)
        } else {
            XCTFail("categoryTitle should carry the Kit bundle, got \(title.bundle)")
        }
    }

    func testEnglishAndChineseTablesCarryTheSameKeys() throws {
        let en = try keys(in: "en")
        let zh = try keys(in: "zh-Hans")
        XCTAssertEqual(en.symmetricDifference(zh), [], "en.lproj and zh-Hans.lproj must list the same keys")
        XCTAssertFalse(zh.isEmpty)
    }

    private func keys(in localization: String) throws -> Set<String> {
        let url = try XCTUnwrap(KitLocalization.bundle(for: localization)?.url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        return Set(table.keys)
    }
}
