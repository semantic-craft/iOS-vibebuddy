import SwiftUI
import VibeBuddyKit

/// The Settings window's own look, replacing `Form(.grouped)`.
///
/// A group is a sentence-case label over a filled card; a row inside it carries
/// a title, an optional explanation, and its control on the trailing edge. The
/// point of hand-drawing it is density: the grouped form spent a whole line on
/// every section header and stacked long footers, so a category could not be
/// read without scrolling. Every category now fits the window at its default
/// size (see `AppWindows.showSettings`).
///
/// Colours and type come from `CompanionPalette` / `MacTheme` like the rest of
/// the app (ADR-0017): Settings is set in the Kit face, not a private one.
enum SettingsChrome {
    static let sidebarWidth: CGFloat = 246
    static let contentMaxWidth: CGFloat = 780
    static let paneInset: CGFloat = 28
    static let cardRadius: CGFloat = 12
    static let rowMinHeight: CGFloat = 50
    static let gridRowMinHeight: CGFloat = 40
    static let columnGap: CGFloat = 18

    /// Row separators sit between rows of one card, so they stay lighter than
    /// the window's own dividers.
    static var hairline: Color { MacTheme.line.opacity(0.75) }

    /// The Kit face at a size and weight; kept as a name so the Settings views
    /// read uniformly, but it is `MacTheme.font`.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        MacTheme.font(size, weight)
    }
}

/// One settings page: its heading and the body beneath it. The body scrolls
/// only if the window is smaller than its minimum content size.
struct SettingsPageScaffold<Content: View>: View {
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    private let content: Content

    init(_ title: LocalizedStringKey,
         subtitle: LocalizedStringKey? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(SettingsChrome.font(18, .bold))
                    .foregroundStyle(MacTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(SettingsChrome.font(12.5, .medium))
                        .foregroundStyle(MacTheme.ink2)
                }
            }
            .padding(.horizontal, SettingsChrome.paneInset)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .frame(maxWidth: SettingsChrome.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, SettingsChrome.paneInset)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacTheme.bg)
    }
}

/// A labelled group of settings: the label, the card, and an optional footnote.
struct SettingsSection<Content: View>: View {
    private let title: LocalizedStringKey
    private let footnote: LocalizedStringKey?
    /// Off for groups whose content brings its own panels — the quota meters
    /// and the spend windows, which read as separate objects rather than rows.
    private let boxed: Bool
    private let content: Content

    init(_ title: LocalizedStringKey,
         footnote: LocalizedStringKey? = nil,
         boxed: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.boxed = boxed
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(SettingsChrome.font(12, .semibold))
                .foregroundStyle(MacTheme.ink2)
                .padding(.horizontal, 2)
                .padding(.top, 19)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)

            if boxed {
                VStack(spacing: 0) { content }
                    // Every row draws a separator above itself; pulling the stack
                    // up by one point hides the first one under the card's clip.
                    .padding(.top, -1)
                    .background(MacTheme.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cardRadius, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 10) { content }
            }

            if let footnote {
                Text(footnote)
                    .font(SettingsChrome.font(11.5))
                    .foregroundStyle(MacTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of a card: title, optional explanation, control on the trailing edge.
struct SettingsRow<Control: View>: View {
    private let titleText: Text
    private let detailText: Text?
    private let control: Control

    init(_ title: LocalizedStringKey,
         detail: LocalizedStringKey? = nil,
         @ViewBuilder control: () -> Control) {
        titleText = Text(title)
        detailText = detail.map { Text($0) }
        self.control = control()
    }

    /// For titles that come from data (a provider name, a phone) and must not
    /// be run through the string table.
    init(verbatim title: String,
         detail: String? = nil,
         @ViewBuilder control: () -> Control) {
        titleText = Text(verbatim: title)
        detailText = detail.map { Text(verbatim: $0) }
        self.control = control()
    }

    /// A localized title whose explanation comes from data — an address, a
    /// delivery record, a message from a provider. Labelled apart from
    /// `detail:` so a string literal never has two overloads to choose from.
    init(_ title: LocalizedStringKey,
         detailText: String?,
         @ViewBuilder control: () -> Control) {
        titleText = Text(title)
        self.detailText = detailText.map { Text(verbatim: $0) }
        self.control = control()
    }

    init(verbatim title: String,
         detail: LocalizedStringKey,
         @ViewBuilder control: () -> Control) {
        titleText = Text(verbatim: title)
        detailText = Text(detail)
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(SettingsChrome.hairline).frame(height: 1)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                        .font(SettingsChrome.font(13, .semibold))
                        .foregroundStyle(MacTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detailText {
                        detailText
                            .font(SettingsChrome.font(12.5))
                            .foregroundStyle(MacTheme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                control
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .frame(minHeight: SettingsChrome.rowMinHeight)
        }
    }
}

/// A row that is all content and no trailing control — a QR code, a status
/// block, a stretch of monospaced output.
struct SettingsBlockRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(SettingsChrome.hairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
        }
    }
}

/// Short label/control pairs laid out two per line. Without this, a page of
/// category switches or CLI states becomes a scrolling column for no reason.
/// A lone last item spans the full width rather than leaving a dead cell.
struct SettingsGrid: View {
    struct Item: Identifiable {
        let id: String
        let title: Text
        let control: AnyView

        init<Control: View>(id: String, title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
            self.id = id
            self.title = Text(title)
            self.control = AnyView(control())
        }

        init<Control: View>(id: String, verbatim title: String, @ViewBuilder control: () -> Control) {
            self.id = id
            self.title = Text(verbatim: title)
            self.control = AnyView(control())
        }

        /// For a title the app already holds as a localized resource.
        init<Control: View>(id: String, text: Text, @ViewBuilder control: () -> Control) {
            self.id = id
            self.title = text
            self.control = AnyView(control())
        }
    }

    let items: [Item]

    private var lines: [[Item]] {
        stride(from: 0, to: items.count, by: 2).map {
            Array(items[$0..<min($0 + 2, items.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: SettingsChrome.columnGap) {
                    ForEach(lines[index]) { cell($0) }
                }
            }
        }
    }

    private func cell(_ item: Item) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(SettingsChrome.hairline).frame(height: 1)
            HStack(alignment: .center, spacing: 12) {
                item.title
                    .font(SettingsChrome.font(13, .semibold))
                    .foregroundStyle(MacTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                item.control
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(minHeight: SettingsChrome.gridRowMinHeight)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The small status word beside a row — "hooked", "stale 2h", "Key saved".
struct SettingsPill: View {
    enum Tone { case neutral, ok, warn, critical }

    private let text: Text
    private let tone: Tone

    init(_ title: LocalizedStringKey, tone: Tone = .neutral) {
        text = Text(title)
        self.tone = tone
    }

    init(verbatim title: String, tone: Tone = .neutral) {
        text = Text(verbatim: title)
        self.tone = tone
    }

    var body: some View {
        text
            .font(SettingsChrome.font(11.5, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(background))
            .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .neutral: MacTheme.ink2
        case .ok: MacTheme.accent
        case .warn: CompanionPalette.status(.requiresInput)
        case .critical: CompanionPalette.status(.error)
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: MacTheme.line.opacity(0.55)
        case .ok: MacTheme.accent.opacity(0.15)
        case .warn: CompanionPalette.status(.requiresInput).opacity(0.17)
        case .critical: CompanionPalette.status(.error).opacity(0.16)
        }
    }
}

/// A quiet action on the trailing edge of a row — a jump to another page, not
/// a change to a setting. The same chrome `HotkeyRecorderView` draws for its
/// combo: label on `bg3` with a hairline, radius 7; pressing lifts the ground.
struct SettingsQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsChrome.font(12.5, .medium))
            .foregroundStyle(MacTheme.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(configuration.isPressed ? MacTheme.bg3.opacity(0.7) : MacTheme.bg3))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(MacTheme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// A value shown on the trailing edge of a row — an address, a count, a date.
struct SettingsValue: View {
    private let text: Text
    private var monospaced = false

    init(_ title: LocalizedStringKey) { text = Text(title) }
    init(verbatim title: String, monospaced: Bool = false) {
        text = Text(verbatim: title)
        self.monospaced = monospaced
    }
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(monospaced ? MacTheme.mono(12.5) : SettingsChrome.font(12.5, .medium))
            .monospacedDigit()
            .foregroundStyle(MacTheme.ink2)
            .textSelection(.enabled)
    }
}
