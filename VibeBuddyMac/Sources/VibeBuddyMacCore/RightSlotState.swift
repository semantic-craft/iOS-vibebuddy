import Foundation

/// The dashboard's right slot, as Cursor's right sidebar behaves: one place
/// that is either the tool shelf (entries), a tool pane (the entry opened,
/// tabs to switch), or a floating rail (collapsed, no column). The pane takes
/// the shelf's place — they never sit side by side — and a window too narrow
/// to hold both the reading column and the slot degrades the slot before it
/// squeezes the reading column, where approvals live.
///
/// Pure value; the view stores it and asks `layout(availableWidth:)` for what
/// to draw. Persisted as one string so `@AppStorage` can hold it.
public struct RightSlotState: Equatable, Sendable, RawRepresentable {
    public enum Mode: String, Sendable { case shelf, pane, rail }
    public enum Tool: String, CaseIterable, Sendable { case changes, output, activity }
    public enum Event: Equatable, Sendable {
        case open(Tool), select(Tool), close, toggleRail, toggleExpanded
    }
    /// What the slot draws for a given detail-column width.
    public enum Layout: Equatable, Sendable {
        case rail, shelf
        /// The pane beside the reading column, at this width.
        case pane(width: CGFloat)
        /// The pane over the whole detail column; `forced` when the window
        /// could not fit both, so the pane offers a way back instead of an
        /// expand toggle.
        case full(forced: Bool)
    }

    public var mode: Mode
    public var tool: Tool
    /// The user asked the pane to fill the detail column.
    public var expanded: Bool
    /// The mode ⌥⌘B returns to from the rail.
    public var restore: Mode

    public static let shelfWidth: CGFloat = 176
    public static let paneMinWidth: CGFloat = 320
    public static let paneMaxWidth: CGFloat = 560
    /// Below this the reading column cannot show a request and its keys.
    public static let readingMinWidth: CGFloat = 400

    public init(mode: Mode = .shelf, tool: Tool = .changes, expanded: Bool = false, restore: Mode = .shelf) {
        self.mode = mode; self.tool = tool; self.expanded = expanded
        self.restore = restore == .rail ? .shelf : restore
    }

    // MARK: RawRepresentable — "mode:tool:expanded:restore"

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let mode = Mode(rawValue: parts[0]), let tool = Tool(rawValue: parts[1]),
              let restore = Mode(rawValue: parts[3]) else { return nil }
        self.init(mode: mode, tool: tool, expanded: parts[2] == "1", restore: restore)
    }
    public var rawValue: String { "\(mode.rawValue):\(tool.rawValue):\(expanded ? "1" : "0"):\(restore.rawValue)" }

    // MARK: Transitions

    public func reduced(_ event: Event) -> RightSlotState {
        var next = self
        switch event {
        case .open(let tool):
            next.mode = .pane; next.tool = tool; next.restore = .pane
        case .select(let tool):
            next.tool = tool
            if next.mode != .pane { next.mode = .pane; next.restore = .pane }
        case .close:
            next.mode = .shelf; next.expanded = false; next.restore = .shelf
        case .toggleRail:
            if next.mode == .rail { next.mode = next.restore } else { next.restore = next.mode; next.mode = .rail }
        case .toggleExpanded:
            guard next.mode == .pane else { return next }
            next.expanded.toggle()
        }
        return next
    }

    /// Fit the slot into `availableWidth` (the detail column). A pane that
    /// cannot sit beside a readable column goes full-width instead of
    /// pretending to open; a shelf that cannot fit collapses to the rail.
    public func layout(availableWidth: CGFloat) -> Layout {
        switch mode {
        case .rail: return .rail
        case .shelf:
            return availableWidth - Self.shelfWidth >= Self.readingMinWidth ? .shelf : .rail
        case .pane:
            if expanded { return .full(forced: false) }
            let room = availableWidth - Self.readingMinWidth
            guard room >= Self.paneMinWidth else { return .full(forced: true) }
            // Grow with the window: ~42 % of the column, within the pane's band.
            let width = min(Self.paneMaxWidth, max(Self.paneMinWidth, (availableWidth * 0.42).rounded()))
            return .pane(width: min(width, room))
        }
    }
}
