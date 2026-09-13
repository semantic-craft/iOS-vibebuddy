import Foundation

/// A read-only result bound to the same source/session/completion as its notice.
public struct CompletionBody: Codable, Equatable, Sendable {
    public var sourceID: String?
    public var sessionID: String
    public var completionID: String
    public var text: String?
    public var unavailableReason: String?
    public init(sourceID: String?, sessionID: String, completionID: String, text: String? = nil, unavailableReason: String? = nil) {
        self.sourceID = sourceID; self.sessionID = sessionID; self.completionID = completionID
        self.text = text; self.unavailableReason = unavailableReason
    }
}

#if os(macOS) || os(iOS)
import SwiftUI

public extension View {
    /// Older OS versions retain explicit read actions rather than inferring
    /// visibility from a body loading somewhere outside the viewport.
    @ViewBuilder func completionReadingVisibility(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(macOS 15, iOS 18, *) {
            onScrollVisibilityChange(threshold: 0.01, action)
        } else { self }
    }
}
#endif
