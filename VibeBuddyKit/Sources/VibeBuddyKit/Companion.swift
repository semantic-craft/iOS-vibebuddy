import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Companion look shared by the Mac, iPhone, Watch, widget and Live
/// Activity: one palette, one type ramp, one set of copy rules
/// (docs/design/mac-companion-redesign.md).
public enum CompanionPalette {
    // Grounds follow Cursor's own app theme (`theme-cursor`), not its marketing
    // site: a neutral near-white canvas over a slightly darker chrome, and the
    // inverse in dark. Cards sit on hairlines, not shadows.
    public static let bg     = dynamic(0xFCFCFC, 0x181818)
    public static let bg2    = dynamic(0xF3F3F3, 0x141414)
    public static let bg3    = dynamic(0xFFFFFF, 0x1F1F1F)
    /// A hairline is translucent ink, so one value works on every ground.
    public static let line   = translucent(0x141414, 0.09, 0xF0F0F0, 0.10)
    public static let ink    = dynamic(0x141414, 0xF0F0F0)
    public static let ink2   = translucent(0x141414, 0.74, 0xF0F0F0, 0.70)
    /// Tertiary ink is still text (row times, group counts, footnotes), so it
    /// composites to >= 4.5:1 on every ground in both appearances (ADR-0017 §8;
    /// the table is in ticket 06 of `.scratch/cursor-visual-language/`).
    public static let ink3   = translucent(0x141414, 0.59, 0xF0F0F0, 0.50)
    /// The buddy's green stays the action colour: Cursor spends its brand
    /// orange on the brand, not on the product's buttons. Darkened for the
    /// neutral ground so white label text keeps its contrast.
    public static let accent = dynamic(0x3E7A4A, 0x7FC48F)
    /// Ground of dark "glance" surfaces: the Mac notch card, the Live Activity.
    public static let glance = dynamic(0x141414, 0x0F0F0F)

    /// Soft status tints for Companion surfaces, taken from Cursor's own
    /// light/dark theme values so they sit calmly on a neutral ground. The neon
    /// `TaskStatusColorToken`s stay the source for the menu-bar badge and
    /// `TaskStatusIndicator`, whose accessibility modes depend on them — the
    /// single exception to "every surface reads these tokens" (ADR-0017 §1).
    public static func status(_ state: TaskPresentationState) -> Color {
        switch state {
        case .error:          return dynamic(0xBE1744, 0xE34671)
        // The light warm and blue are one notch under Cursor's own so the
        // 11.5pt state word clears 4.5:1 on `bg2` as well as `bg`; the hues
        // are unchanged.
        case .requiresInput:  return dynamic(0xC54200, 0xF1B467)
        case .thinking:       return dynamic(0x2572B7, 0x81A1C1)
        case .completeUnread: return accent
        // The idle dot is non-text and holds 3:1 against `bg`.
        case .idle:           return translucent(0x141414, 0.46, 0xF0F0F0, 0.36)
        case .unassigned:     return ink3
        }
    }

    /// Light/dark pair resolved by the platform's appearance. watchOS is
    /// always dark, so it takes the dark value outright.
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        translucent(light, 1, dark, 1)
    }

    /// The same pair with per-appearance opacity, for hairlines and secondary
    /// ink that should composite onto whatever sits behind them.
    static func translucent(_ light: UInt32, _ lightAlpha: CGFloat,
                            _ dark: UInt32, _ darkAlpha: CGFloat) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
                .withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
        #elseif os(iOS)
        return Color(uiColor: UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            return UIColor(hex: isDark ? dark : light)
                .withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
        #else
        return Color(hex: dark).opacity(darkAlpha)
        #endif
    }
}

/// Geist ships with the kit under the SIL OFL. Cursor's own CursorGothic is
/// not distributed, and Geist is the same engineered-gothic register — the
/// face the readings, labels and numbers are set in across all three apps.
enum CompanionFonts {
    static let sans = "Geist"
    static let mono = "Geist Mono"

    /// CoreText registration is process-wide and idempotent; a missing file
    /// just leaves `Font.custom` to fall back to the system face.
    private static let registered: Bool = {
        var ok = true
        for resource in ["Geist", "GeistMono"] {
            guard let url = Bundle.module.url(forResource: resource, withExtension: "ttf") else {
                ok = false
                continue
            }
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { ok = false }
        }
        return ok
    }()

    static func register() { _ = registered }
}

public enum CompanionType {
    /// The packaged Geist face at a size and weight, registered relative to
    /// the system text style nearest that size so Dynamic Type scales it
    /// (ADR-0017 §8). Surfaces whose frame cannot grow use `fixedFont`.
    public static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        CompanionFonts.register()
        return .custom(CompanionFonts.sans, size: size, relativeTo: textStyle(for: size)).weight(weight)
    }
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        CompanionFonts.register()
        return .custom(CompanionFonts.mono, size: size, relativeTo: textStyle(for: size)).weight(weight)
    }
    /// The same faces at a size that ignores Dynamic Type. Only for a frame
    /// that is fixed by hardware or the system: the compact Glance strip, the
    /// Dynamic Island's compact regions, the Watch complications.
    public static func fixedFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        CompanionFonts.register()
        return .custom(CompanionFonts.sans, fixedSize: size).weight(weight)
    }
    public static func fixedMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        CompanionFonts.register()
        return .custom(CompanionFonts.mono, fixedSize: size).weight(weight)
    }
    /// The system text style a Companion size scales with. Monotonic in size,
    /// so a larger token never scales with a smaller ramp than a smaller one.
    public static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ...10: return .caption2
        case ...11: return .caption
        case ...12: return .footnote
        case ...13: return .subheadline
        case ...15: return .body
        case ...17: return .headline
        case ...20: return .title3
        case ...22: return .title2
        case ...26: return .title
        default:    return .largeTitle
        }
    }
    /// Cursor compresses display sizes (-2.16 pt at 72 pt). Titles apply this
    /// through `.tracking()`; body text and captions stay untracked.
    public static func tracking(_ size: CGFloat) -> CGFloat {
        if size >= 20 { return -size * 0.03 }
        if size >= 13 { return -size * 0.012 }
        return 0
    }
    public static let panelRadius: CGFloat = 12
    public static let cardRadius: CGFloat = 8
    /// One hairline, everywhere a card or column needs an edge.
    public static let hairline: CGFloat = 1
}

/// What the cat says about the whole snapshot, and how a request is worded.
public enum CompanionCopy {
    public static func needsYou(_ s: TaskPresentationSummary) -> Int { s.error + s.requiresInput }

    /// `3 things need you` / `1 thing needs you` / `All quiet — 2 working` / `All quiet`.
    public static func moodLine(_ s: TaskPresentationSummary) -> String {
        let n = needsYou(s)
        if n == 1 { return String(localized: "1 thing needs you") }
        if n > 1 { return String(localized: "\(n) things need you") }
        if s.thinking > 0 { return String(localized: "All quiet — \(s.thinking) working") }
        return String(localized: "All quiet")
    }

    /// `3 working · 1 done · 1 idle`, zeros omitted; empty when nothing else runs.
    /// The working count is dropped when `moodLine` already carries it
    /// (`All quiet — 3 working`), so the pair never says it twice. With
    /// something waiting the mood line names the waiting count instead, and the
    /// working count belongs here. A voice phase can replace the mood line;
    /// in that case the rest line keeps the working count.
    public static func restLine(_ s: TaskPresentationSummary, moodLineIsVisible: Bool = true) -> String {
        let moodCarriesWorking = moodLineIsVisible && needsYou(s) == 0 && s.thinking > 0
        return [s.thinking > 0 && !moodCarriesWorking ? String(localized: "\(s.thinking) working") : nil,
                s.completeUnread > 0 ? String(localized: "\(s.completeUnread) done") : nil,
                s.idle > 0 ? String(localized: "\(s.idle) idle") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The verb in `<project> wants to <verb>`, from the tool name.
    public static func requestVerb(tool: String) -> String {
        switch tool.lowercased() {
        case "edit", "multiedit", "notebookedit": return String(localized: "edit")
        case "write": return String(localized: "write")
        case "bash", "shell", "exec": return String(localized: "run")
        case "read": return String(localized: "read")
        case "webfetch", "web_fetch", "websearch", "web_search": return String(localized: "fetch")
        default: return String(localized: "use \(tool)")
        }
    }
    public static func requestVerb(_ approval: PendingApproval) -> String { requestVerb(tool: approval.tool) }
}

/// The three Companion buckets, cut by presentation state (not `SessionStatus`,
/// so an error lands in "Needs you" and an unread completion in "Done").
public struct StateGroups: Equatable, Sendable {
    public let needsYou: [AgentSession]
    public let working: [AgentSession]
    public let done: [AgentSession]

    public init(_ sessions: [AgentSession]) {
        needsYou = sessions.filter { $0.presentationState == .error || $0.presentationState == .requiresInput }
        working = sessions.filter { $0.presentationState == .thinking }
        done = sessions.filter { $0.presentationState == .completeUnread || $0.presentationState == .idle }
    }

    public struct Bucket: Identifiable, Equatable, Sendable {
        public let title: String
        public let sessions: [AgentSession]
        /// The bucket that asks for the user; it wears the warm tint.
        public let warm: Bool
        public var id: String { title }
    }

    /// Non-empty buckets in attention order.
    public var buckets: [Bucket] {
        [Bucket(title: String(localized: "Needs you"), sessions: needsYou, warm: true),
         Bucket(title: String(localized: "Working"), sessions: working, warm: false),
         Bucket(title: String(localized: "Done"), sessions: done, warm: false)]
            .filter { !$0.sessions.isEmpty }
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

#if os(macOS)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
#elseif os(iOS)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
#endif
