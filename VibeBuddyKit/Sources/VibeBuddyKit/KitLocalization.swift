import Foundation

/// The Kit's own string table (ticket 08, ADR-0017). Every user-visible string
/// the Kit produces resolves through `bundle: .module`, never through the host
/// app's table, so the shared copy reads the same on every surface. Exposed so
/// the tests can open the zh-Hans table without a preferred-language override.
public enum KitLocalization {
    public static var bundle: Bundle { .module }

    /// The `.lproj` bundle for one localization, or nil when the table has none.
    /// SwiftPM lowercases the folder (`zh-hans.lproj`) where Xcode keeps the
    /// case, so both spellings are tried.
    public static func bundle(for localization: String) -> Bundle? {
        for name in [localization, localization.lowercased()] {
            if let url = Bundle.module.url(forResource: name, withExtension: "lproj"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }
}
