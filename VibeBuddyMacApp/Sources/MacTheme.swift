import SwiftUI
import VibeBuddyKit

/// Mac-side aliases for the shared Companion look (VibeBuddyKit/Companion.swift,
/// docs/design/mac-companion-redesign.md). Views read `MacTheme.*` so the Mac
/// code stays short; every value comes from the Kit.
enum MacTheme {
    static let bg = CompanionPalette.bg
    static let bg2 = CompanionPalette.bg2
    static let bg3 = CompanionPalette.bg3
    static let line = CompanionPalette.line
    static let ink = CompanionPalette.ink
    static let ink2 = CompanionPalette.ink2
    static let ink3 = CompanionPalette.ink3
    static let accent = CompanionPalette.accent
    /// Ground of the expanded glance card and the capsule-mode pill. The
    /// collapsed pill in notch mode stays pure black so it merges with the
    /// hardware notch.
    static let glance = CompanionPalette.glance

    static func status(_ state: TaskPresentationState) -> Color { CompanionPalette.status(state) }

    static let panelRadius = CompanionType.panelRadius
    static let cardRadius = CompanionType.cardRadius

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { CompanionType.font(size, weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { CompanionType.mono(size, weight) }
}

typealias MacSummaryCopy = CompanionCopy
