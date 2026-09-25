# Accessibility checklist

Every UI change on the Mac app, the iPhone app (with its widgets and Live
Activity) and the Watch app goes through this list before it merges. The bar is
Apple's Human Interface Guidelines, in particular
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[Typography](https://developer.apple.com/design/human-interface-guidelines/typography),
[Motion](https://developer.apple.com/design/human-interface-guidelines/motion) and
[Color](https://developer.apple.com/design/human-interface-guidelines/color). Where the
HIG gives a number, WCAG 2.2 AA gives the formula.

G-4 (2026-09-25) is the first pass against it; its findings and the evidence are in
`docs/design/accessibility-audit-2026-09.md`. This list replaces the G-5
design checklist (closed 2026-09-23 and folded in here).

## 1. VoiceOver

- [ ] **Every control has a name that says what it does.** An icon-only `Button`
      gets `.accessibilityLabel`; `.help` is a tooltip only and VoiceOver does not
      read it. A toggle's label says what pressing it will do now
      ("Start voice conversation" / "End voice conversation"), not "Toggle".
- [ ] **Approve, Deny, Stop and Send name their target.** The key's label stays the
      verb; the command or question goes in `.accessibilityHint` (Mac glance and
      dashboard, iPhone reader, Watch card). A VoiceOver user often swipes straight
      to the key and never hears the card above it.
- [ ] **A card contains its keys; it does not combine them.** Use
      `.accessibilityElement(children: .contain)` on a card that holds buttons, and
      `.combine` only on the read-only part (a header row, a meta line). A combined
      card turns Approve and Deny into entries in the Actions rotor (the Watch alert
      card did this until G-4).
- [ ] **State that is drawn is also said.** A check mark gets `.isSelected`; a
      chevron that folds gets `.accessibilityValue("Expanded" / "Collapsed")`; a
      coloured status dot's meaning goes into the row's label or value. Hide the
      glyph itself (`.accessibilityHidden(true)`), so VoiceOver does not read
      "checkmark.circle.fill".
- [ ] **Decorative art is hidden; its meaning is not lost.** `BuddyCatFace`, status
      dots, separators ("·") and brand marks next to a written name are hidden. The
      pet's state is always available as text elsewhere (the voice strip's phase,
      the glance's count, the menu-bar item's label).
- [ ] **Agent avatars and quota rings are one element each.** `AgentAvatar` and
      `StateGlyph` are `.accessibilityElement(children: .ignore)` + label. A ring,
      bar or complication says whose it is and which way it counts: "Claude, 42%
      left", never "CL, 42%" or a `used` number next to a `left` number.
- [ ] **Nothing that moves the user's work happens silently.** A result that only
      appears as a toast, a status line under a key, or a card that times out is
      posted with `AccessibilityNotification.Announcement` (SwiftUI) or
      `UIAccessibility.post(notification: .announcement, …)`. On the Mac, a glance
      card falls back to a system notification while VoiceOver is running.
- [ ] **Pointer-only paths have an accessible twin.** Hover and `onTapGesture`
      surfaces get `.accessibilityAction` (named where there is more than one) and
      the `.isButton` trait on a single element, never on a `.contain` container.
- [ ] **Invisible shortcut carriers are hidden.** A `Button("")` that only exists
      for `.keyboardShortcut` is `.accessibilityHidden(true)`.
- [ ] **Headings are marked.** Page titles, section heads and "Your decision" carry
      `.isHeader`, so the Headings rotor works.

## 2. Text size

- [ ] **iPhone and Watch text uses `CompanionType.font/mono` or a system text
      style**, which scale with Dynamic Type. `CompanionType.fixedFont` is only for a
      frame fixed by hardware (Dynamic Island compact regions, complications, the
      Mac notch strip), with the reason written next to it.
- [ ] **At accessibility sizes (AX1–AX5) nothing the user decides on is cut.**
      Questions, answer options, commands under approval, "First up" titles and
      state words drop their `lineLimit` or raise it
      (`typeSize.isAccessibilitySize ? nil : n`), and lose `minimumScaleFactor`.
- [ ] **Rows reflow instead of truncating.** An `HStack` of several texts switches to a
      `VStack` at accessibility sizes (`AnyLayout`, `ViewThatFits`, or an
      `if typeSize.isAccessibilitySize`). Grids drop to one column.
- [ ] **Keys stay reachable.** Approve / Deny sit outside a height-capped scroll
      (pinned under it), and side-by-side keys stack when their labels no longer fit.
- [ ] **Fixed-width strips cap and offer the Large Content Viewer.** A tab-like strip
      (the phone's agent strip) uses `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)`
      plus `.accessibilityShowsLargeContentViewer`, like the system tab bar.
- [ ] **Columns sized next to text use `@ScaledMetric`**, not a literal width (Watch
      quota strips).
- [ ] **Mac: information text is never under 10 pt**, including at the Small glance
      preset (`max(10, 10 * s)`). macOS has no Dynamic Type; 9 pt is for glyphs only.

## 3. Motion

- [ ] **Every animation that moves, scales, springs or loops reads
      `@Environment(\.accessibilityReduceMotion)`.** Under Reduce Motion:
      slides and zooms become `.opacity` or no animation; springs become a short
      ease; repeating symbol effects stop (`isActive: !reduceMotion`); programmatic
      scrolls jump (`withAnimation(reduceMotion ? nil : …)`).
- [ ] **The pet is still under Reduce Motion.** `BuddyCatMotion.frame(_:now:reduceMotion:)`
      returns the plain pose (the speaking mouth still switches), and `PetFace` pauses
      its `TimelineView`. Any new animated surface for the cat goes through the same
      function.
- [ ] **Countdown and progress hairlines tick at 1 fps** under Reduce Motion instead
      of 20.
- [ ] Opacity fades and colour changes of 0.1–0.2 s are fine as they are.

## 4. Colour and contrast

- [ ] **Text is ≥ 4.5:1 against its ground** (≥ 3:1 at 18 pt, or 14 pt bold), in
      light *and* dark, and on every ground it can sit on (`bg`, `bg2`, `bg3`, the
      card, the glance black). Meaningful glyphs and edges are ≥ 3:1.
- [ ] **A label on a coloured fill uses `Color.onAccent`**, never `.white`. The dark
      mint accent with white text is 2.06:1; `onAccent` is 9.09:1 there and 4.8:1 on
      the dark red.
- [ ] **A surface whose ground is always dark resolves dark tokens.** The Mac glance
      panel is `.darkAqua`; the Live Activity lock-screen view sets
      `.environment(\.colorScheme, .dark)`. Otherwise light-mode status colours land
      on black at 3:1.
- [ ] **No `Color.orange` / `Color.red` for text.** Use `CompanionPalette.status(_:)`,
      whose values are tuned for 4.5:1 on the Companion grounds.
- [ ] **Status is never colour alone.** Rows carry a state word; `StatusDot` draws the
      state's symbol when Differentiate Without Color is on; `TaskStatusIndicator`
      already does.
- [ ] **Increase Contrast works.** Translucent tokens (`line`, `ink2`, `ink3`, idle)
      close half their gap to opaque under Increase Contrast
      (`CompanionPalette.contrasted`). New translucent tokens go through
      `CompanionPalette.translucent` to get this for free.

## 5. Hit targets

- [ ] **iPhone: 44 × 44 pt** for every tappable thing (HIG). Keys that draw smaller
      keep their look and add invisible slop: pad, `contentShape`, un-pad
      (`PhoneButtonStyle`, the reply-cancel ✕). Neighbouring 44 pt targets must not
      overlap (keep ≥ 14 pt between 30 pt circles).
- [ ] **Watch: rows ≥ 38 pt tall, keys full width.**
- [ ] **Mac: ≥ 20 × 20 pt** for an icon button, including the notch's link buttons at
      the Small preset.

## 6. How to check

Agents run these; none of them is an owner step.

- **Audit (iPhone, Watch):** install the demo build on a simulator of your own, then
  `A11Y_PHONE_UDID=<udid> tools/a11y-audit/audit.sh phone <out> [size]` (or `watch`
  with `A11Y_WATCH_UDID`). It launches each demo page (`VIBEBUDDY_DEMO=1`), runs
  `XCUIApplication.performAccessibilityAudit()` and writes `issues.jsonl`, the element
  tree and a screenshot per page. Run it at the default size and at
  `UICTContentSizeCategoryAccessibilityXXXL`. Treat `textClipped` on single-line
  labels at the default size as a Geist line-metric false positive unless the
  screenshot shows a cut. The element tree is the VoiceOver check: a card that
  shows up as one `Button` whose label ends in "…, Approve" has swallowed its keys.
- **Mac:** launch the isolated demo instance (`VIBEBUDDY_DEMO=1`, see
  `docs/agents/skills/verify-vibebuddy`; never the installed copy), then
  `swiftc tools/a11y-audit/axdump.swift -o /tmp/axdump && /tmp/axdump <pid>` prints
  every element in VoiceOver order with its label, value, `SELECTED` state and
  actions. Accessibility Inspector reads the same tree.
- **Appearance and Increase Contrast** on a simulator: `xcrun simctl ui <udid>
  appearance dark` and `xcrun simctl ui <udid> increase_contrast enabled`.
  **Reduce Motion** has no simulator switch: check the code path (every
  `withAnimation` / `.animation` / `.transition` / `symbolEffect` near a
  `reduceMotion` read). The user's own Mac accessibility settings are never changed
  by an agent.
- **Contrast numbers:** composite translucent tokens onto their ground first, then
  apply the WCAG formula. The table of current values is in the G-4 findings doc.
