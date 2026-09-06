import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Companion look shared by the Mac, iPhone, Watch, widget and Live
/// Activity: one palette, one type ramp, one set of copy rules
/// (docs/design/mac-companion-redesign.md).
public enum CompanionPalette {
    public static let bg     = dynamic(0xF5F7FC, 0x21242D)
    public static let bg2    = dynamic(0xEDF1F9, 0x282C37)
    public static let bg3    = dynamic(0xFFFFFF, 0x303542)
    public static let line   = dynamic(0xE0E5F0, 0x3B4152)
    public static let ink    = dynamic(0x2B3247, 0xEEF0F6)
    public static let ink2   = dynamic(0x6C7590, 0xA3AABD)
    public static let ink3   = dynamic(0xA8B0C4, 0x6B7389)
    public static let accent = dynamic(0x5DA868, 0x8AC37E)
    /// Ground of dark "glance" surfaces: the Mac notch card, the Live Activity.
    public static let glance = dynamic(0x2B3247, 0x151820)

    /// Soft status tints for Companion surfaces. The neon
    /// `TaskStatusColorToken`s stay the source for the menu-bar badge and
    /// `TaskStatusIndicator`, whose accessibility modes depend on them.
    public static func status(_ state: TaskPresentationState) -> Color {
        switch state {
        case .error:          return Color(hex: 0xE8636B)
        case .requiresInput:  return Color(hex: 0xF2A03D)
        case .thinking:       return Color(hex: 0x5B8DEF)
        case .completeUnread: return Color(hex: 0x5DA868)
        case .idle:           return Color(hex: 0xB4BACB)
        case .unassigned:     return ink3
        }
    }

    /// Light/dark pair resolved by the platform's appearance. watchOS is
    /// always dark, so it takes the dark value outright.
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #elseif os(iOS)
        return Color(uiColor: UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        return Color(hex: dark)
        #endif
    }
}

public enum CompanionType {
    /// The rounded system face at a size and weight (the prototype's Nunito).
    public static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    public static let panelRadius: CGFloat = 20
    public static let cardRadius: CGFloat = 12
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
    public static func restLine(_ s: TaskPresentationSummary) -> String {
        [s.thinking > 0 ? String(localized: "\(s.thinking) working") : nil,
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
