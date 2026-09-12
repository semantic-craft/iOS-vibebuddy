# ADR-0017: Cursor's visual language on every surface

- Status: accepted
- Date: 2026-09-12
- Supersedes / amends: the *Tokens* section and round 1 ("the cat is the
  protagonist") of `docs/design/mac-companion-redesign.md`; amends ADR-0007
  (where the cat draws) a fifth time; builds on ADR-0014 (iPhone) and ADR-0015
  (menu panel), which applied this register to one surface each.

## Context

Between 2026-09-06 and 2026-09-12 the product's look moved in three steps:
the Companion palette (soft blue-grey, rounded type, pill controls, the cat as
protagonist), then the iPhone's flat grouped list (ADR-0014) and the menu
panel's (ADR-0015) in Cursor's register, then the Kit's tokens themselves
(`aa1b357`: neutral grounds, translucent hairlines, Geist). Those steps landed
on different branches, and one session had ruled the opposite way for Settings
(keep the Companion palette, set it in SF Pro). The result was three faces in
one Mac app — Geist in the dashboard and panel, SF Pro in Settings, the rounded
system face in the Glance and the Watch's quota page — and a cat that led the
Watch and the Glance but not the phone or the panel.

On 2026-09-12 the owner settled it: **the visual language follows Cursor on
every surface, the phone included; wherever no decision exists, follow
Cursor's iOS and macOS apps.** The gaps a same-day review listed were to be
closed the same way.

## Decision

1. **One token set, in the Kit.** `CompanionPalette`, `CompanionType` and
   `CompanionFonts` in `VibeBuddyKit/Sources/VibeBuddyKit/Companion.swift` are
   the only source of colour, type, radius and edge treatment. Grounds are
   Cursor's own app theme (near-white canvas over slightly darker chrome, the
   inverse in dark); hairlines are translucent ink; the buddy's green stays
   the action colour, darkened for the neutral ground; type is Geist and Geist
   Mono, packaged under the SIL OFL; panel and card radii are 12 / 8; cards sit
   on a hairline, never a shadow. The Mac's `MacTheme` is an alias. No surface
   keeps a private font or palette; the one exception is the Kit's neon
   `TaskStatusColorToken`, which still feeds the menu-bar badge and
   `TaskStatusIndicator` because accessibility modes depend on it.
2. **No mascot on status surfaces.** Cursor has none. The cat keeps three
   places — the app icon, the menu-bar mark, and the voice companion's avatar
   while a conversation is running — and leaves every status surface: the
   iPhone list (ADR-0014), the menu panel (ADR-0015), the Watch home, the
   Glance, the Mac dashboard's top bar, the Live Activity and the widgets.
   Empty states use `moon.zzz`.
3. **The voice companion's entry is a mic circle, everywhere.** The iPhone
   composer (always visible), the panel's command row, the dashboard's sidebar
   (Voice row, since 2026-09-13; the top bar before that),
   the expanded Glance and the Watch home carry the same control, whose glyph
   follows the voice phase. It is explained once, the first time it appears.
4. **Status is a dot and a word.** One status dot per row plus the
   `ToolActivity` word in the state's colour; group heads carry a title and a
   count. No tinted blocks, rails or stripes.
5. **The three attention groups are the shared vocabulary.** `StateGroups`
   (Needs you / Working / Done) names the groups on the phone, in the panel,
   in the dashboard and in the Watch's counts. The phone may additionally
   group by project or agent; no other surface offers that.
6. **One fact in one place.** Account quota is read in the dashboard's plinth
   and its Usage page; Settings › Plan & quota holds the threshold and a link,
   not another reading.
7. **Surfaces Cursor does not have take the tokens, not a layout.** The Watch
   keeps its black ground and full-strength status colours; the Glance keeps
   the Dynamic Island grammar of ADR-0011; the widgets keep their frames.
8. **Accessibility is fixed in the token values.** Tertiary ink and the idle
   dot are raised to WCAG AA; labels on the accent use an on-accent colour
   that flips to ink on the dark mint; type is registered relative to the
   system ramp so Dynamic Type works, with fixed sizes only where a frame is
   fixed (compact Glance, complications, widgets).

## Consequences

- The Companion document's *Tokens* table and its "cat is the protagonist"
  round are history; its copy rules, the summary-first row, the request card
  and the Glance's two keys still stand and are re-expressed in the new tokens.
- `docs/design/mac-companion-redesign.md`'s promise that "the same rules
  carry to the Watch" is restored by re-skinning the Watch, not by exempting
  it.
- ADR-0007 is amended again: the cat's remaining places are the three above.
  `BuddyCatFace` stays in the Kit for them; nothing else draws it.
- The phone's 24-hour recency window (ADR-0014) grows into a Kit-wide rule
  for which sessions count as *current* on every summary line, so no surface
  reports "All quiet" while another still counts or reminds. That rule is its
  own change (spec `.scratch/cursor-visual-language/`, ticket 03) and will be
  recorded in `CONTEXT.md` when it lands.
- Implementation is tracked as tickets 01–09 in
  `.scratch/cursor-visual-language/`. As of this ADR the tokens, the iPhone
  list, the menu panel and the Settings pages are on the branch; the font
  migration of the remaining Mac views, the Watch, the mascot's exit from the
  Glance, dashboard, Live Activity and widgets, the mic on those surfaces, the
  accessibility values and the localization are not yet.
