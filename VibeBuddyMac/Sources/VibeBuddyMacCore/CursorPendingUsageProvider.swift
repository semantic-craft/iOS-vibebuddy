import Foundation

/// Placeholder until the Cookie + `usage-summary` collector lands (#104).
///
/// Keeps Cursor first-class in the quota vocabulary while always producing an
/// explicit unavailable reason — never a silent omission and never a fake 0%.
public struct CursorPendingUsageProvider: AccountUsageProviding {
    public init() {}

    public func fetch() async throws -> AccountUsageSnapshot {
        // #104 replaces this with session-cookie auth. Until then, "not signed in"
        // is the clearest existing reason string for missing Cursor credentials.
        throw AccountUsageError.notLoggedIn
    }
}
