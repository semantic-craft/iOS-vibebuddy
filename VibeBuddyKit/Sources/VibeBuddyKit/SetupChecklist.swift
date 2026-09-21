import Foundation

/// The public destinations both companions point at during setup. One place,
/// so the iPhone's "send to my Mac" link and the Mac's App Store QR can never
/// drift apart.
public enum CompanionLinks {
    /// Storefront-agnostic App Store link: no `/us/` segment, so a phone on
    /// any storefront lands on its own listing instead of a redirect.
    public static let iPhoneAppStore = URL(string: "https://apps.apple.com/app/id6777469338")!
    /// The direct-distribution DMG (Developer ID + Sparkle), not a store.
    public static let macDownload = URL(string: "https://github.com/semantic-craft/iOS-vibebuddy/releases/latest")!
}

/// An ordered, order-agnostic setup checklist: every step reports whether it
/// is done, and the first undone step is the one the UI puts forward. Both
/// companions use it — the phone for "install Mac app → pair", the Mac for
/// "hook agents → install iPhone app → pair" — so highlighting and the
/// "n of m done" line come from one tested rule.
public struct SetupChecklist<Step: Hashable>: Equatable {
    public struct Item: Equatable {
        public let step: Step
        public let done: Bool
        public init(_ step: Step, done: Bool) {
            self.step = step
            self.done = done
        }
    }

    public let items: [Item]

    public init(_ items: [Item]) { self.items = items }

    /// The step the UI should highlight: the first one not yet done.
    public var current: Step? { items.first { !$0.done }?.step }
    public var doneCount: Int { items.filter(\.done).count }
    public var total: Int { items.count }
    public var isComplete: Bool { current == nil }

    /// 1-based position, for "Step 2 of 3" labels and VoiceOver.
    public func position(of step: Step) -> Int? {
        items.firstIndex { $0.step == step }.map { $0 + 1 }
    }

    public func isDone(_ step: Step) -> Bool {
        items.first { $0.step == step }?.done ?? false
    }
}
