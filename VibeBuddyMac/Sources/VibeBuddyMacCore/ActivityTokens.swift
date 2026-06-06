import Foundation

/// The set of live iOS Live Activity **push tokens** currently registered by paired
/// phones (`dynamic-island/02`). Separate from `DeviceTokens`: an activity push token
/// has its own lifecycle (one per running activity, rotates over time) and is pushed
/// with `apns-push-type: liveactivity`, not `alert`. In-memory; phones re-register on
/// each launch / token rotation.
public actor ActivityTokens {
    private var tokens: Set<String> = []
    public init() {}
    public func register(_ token: String) {
        guard !token.isEmpty else { return }
        tokens.insert(token)
    }
    public func remove(_ token: String) { tokens.remove(token) }
    public func all() -> [String] { Array(tokens) }
}
